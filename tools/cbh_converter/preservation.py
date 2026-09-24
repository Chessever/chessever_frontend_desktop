"""Explicit, reversible CBH extensions, not guessed PGN semantics.

Version-1 plain text/formatting and version-3 HTML containers retain their titles,
language bodies and exact source bytes. Their layouts are corroborated by the
local Morphy TextContentsModel reference. Unknown formatting and embedded objects
are archived, not guessed. HTML is inert; no referenced resource is fetched.
"""
import base64
import json
from html.parser import HTMLParser
import chess.pgn


def encoded(raw):
    return base64.b64encode(raw).decode('ascii')


class BodyText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.body = False
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == 'body': self.body = True
        if tag in ('script', 'style'): self.hidden += 1
        if self.body and tag in ('p', 'div', 'br', 'li', 'tr'): self.parts.append('\n')
        if self.body and not self.hidden and tag == 'img':
            attributes = dict(attrs)
            self.parts.append(' [Image: ' + (attributes.get('alt') or attributes.get('src') or 'unnamed') + '] ')

    def handle_endtag(self, tag):
        if tag == 'body': self.body = False
        if tag in ('script', 'style') and self.hidden: self.hidden -= 1
        if self.body and tag in ('p', 'div', 'li', 'tr'): self.parts.append('\n')

    def handle_data(self, data):
        if self.body and not self.hidden: self.parts.append(data)


def guiding_game(raw, index):
    """Bounded v1/v3 text framing, corroborated by Morphy TextContentsModel.

    Titles precede the language bodies. V1 has separate formatting/object bytes
    in this same CBG container, not a CBA pointer in the guiding index.
    """
    if len(index) != 46 or len(raw) < 11 or raw[0] != 0x80 or int.from_bytes(raw[1:4], 'big') != len(raw):
        raise ValueError('Invalid guiding-text frame')
    cursor = 4

    def take(size):
        nonlocal cursor
        if size < 0 or size > len(raw) - cursor:
            raise ValueError('Truncated guiding-text entry')
        value = raw[cursor:cursor + size]
        cursor += size
        return value

    def number(size):
        return int.from_bytes(take(size), 'little')

    def render(data):
        from adapter import comment_text
        value = comment_text(data.decode('latin1'))
        # Object/control identities remain visible, never stripped or guessed.
        value = ''.join(f'[ChessBase object 0x{ord(c):02X}]' if ord(c) < 32 and c not in '\t\r\n'
                        else c for c in value)
        return ' '.join(value.split()).replace('{', '&#123;').replace('}', '&#125;')

    version = number(2)
    if version not in (1, 3):
        raise ValueError('Unsupported guiding-text version/encoding')
    comments = []
    for _ in range(number(2)):
        language = number(2)
        title = render(take(number(2)))
        if title:
            comments.append(f'Title (language {language}): {title}')
    flag = number(1)
    if flag not in (0, 1) or (version == 3 and flag != 1):
        raise ValueError('Unsupported guiding-text flag; no content discarded')
    formatting_present = False
    for _ in range(number(2)):
        language = number(2)
        data = take(number(2 if version == 1 else 4))
        if version == 1:
            formatting_present |= bool(take(number(2)))
            value = render(data)
        else:
            if take(4) != bytes(4):
                raise ValueError('Unsupported guiding-text trailer; no content discarded')
            from adapter import comment_text
            parser = BodyText()
            parser.feed(comment_text(data.decode('latin1')))
            parser.close()
            # HTML entities are already Unicode, not native byte transport.
            value = ' '.join(''.join(parser.parts).split()).replace('{', '&#123;').replace('}', '&#125;')
        if value:
            comments.append(f'Language {language}: {value}')
    if cursor != len(raw):
        raise ValueError('Unconsumed guiding-text content')
    game = chess.pgn.Game()
    game.headers['ChessBaseRecordType'] = 'GuidingText'
    game.headers['ChessBaseIndex'] = encoded(index)
    game.headers['ChessBaseGuidingText'] = encoded(raw)
    game.headers['ChessBasePreservation'] = 'v1; original index and text container in base64; root is a text rendering'
    if formatting_present:
        game.headers['ChessBaseGuidingRendering'] = 'plain text; original formatting and embedded objects archived, not rendered'
    game.comment = '\n'.join(comments) if comments else 'ChessBase guiding text: empty bodies.'
    return game


def preserve_annotations(game, entries):
    """Retain order, duplicates, original addresses and every uninterpreted byte."""
    data = [dict(move=e['move'], type=e['type'], hex=e['payloadBytes'].encode('latin1').hex()) for e in entries]
    game.headers['ChessBaseRawAnnotations'] = encoded(json.dumps(data, separators=(',', ':')).encode('ascii'))
    game.headers['ChessBasePreservation'] = 'v1; raw annotations are an original-source archive; addresses are not rebound after edits'
