"""Explicit, reversible CBH extensions, not guessed PGN semantics.

The version-3 HTML container layout is independently derived from framed source
bytes. Only the validated UTF-8/zero-trailer profile is rendered. Original index
and container bytes remain in PGN headers, even for empty documents. HTML is
parsed as inert text, never executed and no referenced resource is fetched.
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

    def handle_endtag(self, tag):
        if tag == 'body': self.body = False
        if tag in ('script', 'style') and self.hidden: self.hidden -= 1
        if self.body and tag in ('p', 'div', 'li', 'tr'): self.parts.append('\n')

    def handle_data(self, data):
        if self.body and not self.hidden: self.parts.append(data)


def guiding_game(raw, index):
    if len(index) != 46 or len(raw) < 11 or raw[0] != 0x80 or int.from_bytes(raw[1:4], 'big') != len(raw):
        raise ValueError('Invalid guiding-text frame')
    if raw[4:9] != b'\x03\0\0\0\x01':
        raise ValueError('Unsupported guiding-text version/encoding')
    count = int.from_bytes(raw[9:11], 'little')
    cursor = 11
    comments = []
    for _ in range(count):
        if cursor + 6 > len(raw): raise ValueError('Truncated guiding-text entry')
        language = int.from_bytes(raw[cursor:cursor + 2], 'little')
        size = int.from_bytes(raw[cursor + 2:cursor + 6], 'little')
        cursor += 6
        if size > len(raw) - cursor - 4: raise ValueError('Truncated guiding-text HTML')
        html = raw[cursor:cursor + size].decode('utf8', errors='strict')
        cursor += size
        if raw[cursor:cursor + 4] != bytes(4):
            raise ValueError('Unsupported guiding-text trailer; no content discarded')
        cursor += 4
        parser = BodyText(); parser.feed(html); parser.close()
        value = ' '.join(''.join(parser.parts).split())
        if value:
            # Braces cannot be represented literally in a PGN brace comment.
            # The exact original remains in ChessBaseGuidingText.
            value = value.replace('{', '&#123;').replace('}', '&#125;')
            comments.append(f'Language {language}: {value}')
    if cursor != len(raw): raise ValueError('Unconsumed guiding-text content')
    game = chess.pgn.Game()
    game.headers['ChessBaseRecordType'] = 'GuidingText'
    game.headers['ChessBaseIndex'] = encoded(index)
    game.headers['ChessBaseGuidingText'] = encoded(raw)
    game.headers['ChessBasePreservation'] = 'v1; original index and HTML container in base64; root is a text rendering'
    game.comment = '\n'.join(comments) if comments else 'ChessBase guiding text: empty HTML bodies.'
    return game


def preserve_annotations(game, entries):
    """Retain order, duplicates, original addresses and every uninterpreted byte."""
    data = [dict(move=e['move'], type=e['type'], hex=e['payloadBytes'].encode('latin1').hex()) for e in entries]
    game.headers['ChessBaseRawAnnotations'] = encoded(json.dumps(data, separators=(',', ':')).encode('ascii'))
    game.headers['ChessBasePreservation'] = 'v1; raw annotations are an original-source archive; addresses are not rebound after edits'
