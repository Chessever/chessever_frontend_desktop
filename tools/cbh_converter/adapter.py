"""Strict move-tree adapter. Derived from the local fidelity-tested adapter."""
import chess
import chess.pgn

def text(raw):
    return raw.encode('latin1').decode('cp1252', errors='strict')


def comment_text(raw):
    # Text annotations may contain UTF-8 even in otherwise legacy databases.
    # This is an explicit rendering policy, not encoding autodetection. Raw
    # bytes are preserved by the publisher so ambiguous strings remain exact.
    data = raw.encode('latin1')
    try:
        return data.decode('utf8', errors='strict')
    except UnicodeDecodeError:
        return data.decode('cp1252', errors='strict')


def make_game(record, is960, *, allow_unsupported=False, preserve_raw=False):
    if record.get('unconsumedAnnotations') and not preserve_raw:
        raise ValueError('unattached annotation content; conversion refused')
    if record.get('unsupportedAnnotations') and not (allow_unsupported or preserve_raw):
        raise ValueError('unsupported annotation content; conversion refused')
    game = chess.pgn.Game()
    board = chess.Board(record['fen'], chess960=is960)
    game.setup(board)
    for key, raw in [('White', 'white'), ('Black', 'black'), ('Event', 'event'), ('Site', 'site')]:
        game.headers[key] = text(record[raw]) or '?'
    game.headers['Date'] = '.'.join(f'{v:0{w}d}' if v else '?' * w for v, w in zip(record['date'], [4, 2, 2]))
    game.headers['Round'] = str(record['round']) if record['round'] else '?'
    if record['subround']:
        game.headers['Round'] += '.' + str(record['subround'])
    game.headers['Result'] = ['*', '1-0', '0-1', '1/2-1/2'][record['result']]
    for tag, key in [('WhiteElo', 'whiteElo'), ('BlackElo', 'blackElo')]:
        if record[key]:
            game.headers[tag] = str(record[key])
    if record.get('eco'):
        game.headers['ECO'] = record['eco']
    if any(record.get('eventDate', [])):
        game.headers['EventDate'] = '.'.join(f'{v:0{w}d}' if v else '?' * w for v, w in zip(record['eventDate'], [4, 2, 2]))
    for name, value in record['tags']:
        # Extra metadata only; mandatory roster is derived above.
        if name not in game.headers:
            game.headers[name] = text(value)
    for comment in record.get('pregameComments', []):
        if comment['kind'] not in ('before', 'after'):
            raise ValueError('unsupported annotation at game root')
        game.comment = (game.comment + ' ' + comment_text(comment['textBytes'])).strip()
    moves = record['moves']

    def line(index, parent, position, depth=0):
        if depth > 100:
            raise ValueError('variation depth exceeded')
        while index < len(moves):
            m = moves[index]
            index += 1
            promotion = m['promotion']
            if promotion == 255:
                index = line(index, parent, position.copy(), depth + 1)
                continue
            if promotion == 254:
                return index
            if promotion == 253:
                raise ValueError('decoder returned MoveSkip; not silently accepted')
            if promotion == 6:
                move = chess.Move.null()
            elif promotion == 1:
                # Position::makeMove uses king-to-rook coordinates for 960,
                # but king-to-destination coordinates for orthodox chess.
                candidates = [c for c in position.generate_castling_moves()
                              if c.from_square == m['from'] and c.to_square == m['to']]
                if len(candidates) != 1:
                    raise ValueError('castling encoding cannot be resolved')
                move = candidates[0]
            else:
                piece = {2: chess.QUEEN, 3: chess.ROOK, 4: chess.BISHOP, 5: chess.KNIGHT, 7: None}[promotion]
                move = chess.Move(m['from'], m['to'], promotion=piece)
                if move not in position.legal_moves:
                    raise ValueError(f'illegal decoded move {move.uci()} in {position.fen()}')
            node = parent.add_variation(move)
            for comment in m['comments']:
                kind = comment['kind']
                if kind in ('before', 'after'):
                    value = comment_text(comment['textBytes'])
                    if kind == 'before' and node.starts_variation():
                        node.starting_comment = (node.starting_comment + ' ' + value).strip()
                    else:
                        target = parent if kind == 'before' else node
                        target.comment = (target.comment + ' ' + value).strip()
                elif kind == 'symbols':
                    node.nags.update(comment[k] for k in ('symbol', 'evaluation', 'prefix') if comment[k])
                elif kind == 'arrow':
                    color = {'red': 'R', 'green': 'G', 'yellow': 'Y'}[comment['color']]
                    node.comment += f" [%cal {color}{chess.square_name(comment['from'])}{chess.square_name(comment['to'])}]"
                elif kind == 'square':
                    color = {'red': 'R', 'green': 'G', 'yellow': 'Y'}[comment['color']]
                    node.comment += f" [%csl {color}{chess.square_name(comment['square'])}]"
            position.push(move)
            parent = node
        return index

    consumed = line(0, game, board)
    if consumed != len(moves):
        raise ValueError('unconsumed move tokens')
    if preserve_raw and record.get('rawAnnotations'):
        from preservation import preserve_annotations
        preserve_annotations(game, record['rawAnnotations'])
        game.headers['ChessBaseCommentEncoding'] = 'UTF-8 if valid; otherwise Windows-1252; raw bytes retained'
        if record.get('unconsumedAnnotations'):
            game.headers['ChessBaseUnattachedAnnotations'] = 'true'
    elif preserve_raw and (record.get('unsupportedAnnotations') or record.get('unconsumedAnnotations')):
        raise ValueError('Native raw annotation inventory is required')
    return game


def normalize_comment(value):
    return ' '.join(value.split())


def tree(node, annotations=False):
    # Iterative representation avoids Python recursion limits on long games.
    records = []
    pending = [((), node)]
    while pending:
        path, current = pending.pop()
        entry = [path, current.move.uci() if current.move else None]
        if annotations:
            entry.extend([sorted(current.nags), normalize_comment(current.comment), normalize_comment(current.starting_comment)])
        records.append(entry)
        pending.extend((path + (i,), child) for i, child in reversed(list(enumerate(current.variations))))
    return records
