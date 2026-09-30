/*
 * Copyright (C) 2026 Roland Lötscher.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
 * THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include "cbh_decode_annotation.h"
#include "mapping.h"
#include "nags.h"
#include <iomanip>
#include <sstream>

constexpr int ANNOTATION_HEADER_SIZE = 26;
constexpr int ANNOTATION_ENTRY_SIZE = 62;

// CBH 0x07 stores elapsed H/M/S plus an auxiliary byte; 0x21 stores
// signed little-endian evaluation/type/depth. Keep the auxiliary byte as a
// separate extension, never reinterpret elapsed time as remaining clock time.
static std::string timedAnnotation(byte type, const byte* p, uint32_t size) {
	std::ostringstream out;
	if (type == 0x07 && size == 4 && p[1] < 60 && p[2] < 60) {
		out << "[%emt " << unsigned(p[0]) << ':' << std::setfill('0')
		    << std::setw(2) << unsigned(p[1]) << ':' << std::setw(2)
		    << unsigned(p[2]) << ']';
		if (p[3]) out << " [%cbh_emt_flags " << unsigned(p[3]) << ']';
	} else if (type == 0x21 && size == 6) {
		auto signed16 = [](const byte* v) {
			const int n = int(v[0]) | int(v[1]) << 8;
			return n >= 0x8000 ? n - 0x10000 : n;
		};
		const int value = signed16(p), kind = signed16(p + 2), depth = signed16(p + 4);
		if ((kind != 0 && kind != 1) || depth < 0) return {};
		out << "[%eval ";
		if (kind == 1) out << '#' << value;
		else {
			if (value < 0) out << '-';
			const int magnitude = value < 0 ? -value : value;
			out << magnitude / 100 << '.' << std::setfill('0') << std::setw(2) << magnitude % 100;
		}
		if (depth) out << ',' << depth;
		out << ']';
	}
	return out.str();
}

// Morphy e171eba4 TimeSerie: three big-endian 11-byte periods.
// Render only verified stages ending in sudden death. Unknown trailing bytes,
// fractional seconds and unsupported types remain raw, never guessed away.
static std::string timeControl(const byte* p, uint32_t size) {
	if (size != 33) return {};
	auto big32 = [](const byte* v) {
		return uint32_t(v[0]) << 24 | uint32_t(v[1]) << 16 | uint32_t(v[2]) << 8 | v[3];
	};
	std::string result;
	bool ended = false;
	for (uint32_t offset : {0u, 11u, 22u}) {
		const byte* v = p + offset;
		const uint32_t start = big32(v), increment = big32(v + 4);
		const uint moves = uint(v[8]) << 8 | v[9];
		const uint type = v[10];
		if (ended) {
			if (start || increment || !((moves == 0 && type == 0) || (moves == 1000 && type == 5))) return {};
			continue;
		}
		if (start >= 0x80000000u || increment >= 0x80000000u || start % 100 || increment % 100) return {};
		if (type == 1) {
			if (!moves || moves >= 1000) return {};
		} else if ((type == 0 || type == 3) && moves == 1000 && (type == 3 || !increment)) {
			ended = true;
		} else return {};
		if (!result.empty()) result += ':';
		if (type == 1) result += std::to_string(moves) + '/';
		result += std::to_string(start / 100);
		if (increment || type == 3) result += "+" + std::to_string(increment / 100);
	}
	return ended ? result : std::string{};
}

// Verified byte layouts: Yarin78/morphy e171eba4 annotation serializers.
// Render readable labels, not guessed native styling. Raw bytes remain archived.
static std::string positionAnnotation(byte type, const byte* p, uint32_t size) {
	std::ostringstream out;
	if (type == 0x18 && size == 1 && p[0] >= 1 && p[0] <= 3) {
		const char* names[] = {"", "opening", "middlegame", "endgame"};
		out << "Critical " << names[p[0]] << " position";
	} else if (type == 0x22 && size == 4 && p[0] == 0 && p[1] == 0) {
		const char* names[] = {"Best game", "Decided tournament", "Model game", "Novelty",
			"Pawn structure", "Strategy", "Tactics", "With attack", "Defense", "Sacrifice",
			"Material", "Piece play", "Endgame", "Tactical blunder", "Strategical blunder", "User"};
		const uint flags = uint(p[2]) << 8 | p[3];
		if (!flags) return {};
		out << "ChessBase medals: ";
		bool first = true;
		for (uint i = 0; i < 16; ++i) if (flags & (1u << i)) {
			if (!first) out << ", ";
			out << names[i]; first = false;
		}
	} else if (type == 0x23 && size == 4 && p[0] <= 3) {
		out << "ChessBase variation color: #" << std::uppercase << std::hex << std::setfill('0')
		    << std::setw(2) << unsigned(p[3]) << std::setw(2) << unsigned(p[2])
		    << std::setw(2) << unsigned(p[1]) << " ("
		    << ((p[0] & 2) ? "moves only" : "moves and annotations") << ", "
		    << ((p[0] & 1) ? "mainline only" : "including sublines") << ')';
	}
	return out.str();
}

static inline std::string colorName(byte col) {
	switch (col) {
	case 2:
		return "green";
	case 3:
		return "yellow";
	case 4:
		[[fallthrough]];
	default:
		return "red";
	}
}

CbhAnnotationDecoder::CbhAnnotationDecoder(const char* filename)
    : CbhDecoder(filename) {}

errorT CbhAnnotationDecoder::decode_header() {
	if (auto err = stream_.open(filename_, FMODE_ReadOnly))
		return err;

	return OK;
}

void CbhAnnotationDecoder::decodeSquares(std::vector<Comment>& comments,
                                         const char* content, int length) {
	for (int i = 0; 2 * i < length; i++) {
		std::string col = colorName(content[2 * i]);
		squareT square = mapSquare(content[2 * i + 1] - 1);
		comments.push_back(SquareComment(square, col));
	}
}

void CbhAnnotationDecoder::decodeArrows(std::vector<Comment>& comments,
                                        const char* content, int length) {
	for (int i = 0; 3 * i < length; i++) {
		std::string col = colorName(content[3 * i]);
		squareT sqFrom = mapSquare(content[3 * i + 1] - 1);
		squareT sqTo = mapSquare(content[3 * i + 2] - 1);
		comments.push_back(ArrowComment(sqFrom, sqTo, col));
	}
}

void CbhAnnotationDecoder::decodeSymbol(std::vector<Comment>& comments,
                                        const byte* content, int length,
                                        colorT sideToMove) {
	if (length == 0)
		return;
	SymbolComment comment;
	// Preserve the stored PGN identities; deriving color-specific Scid NAGs
	// from the mover changed evaluations in the supplied reference exports.
	switch (content[0]) {
	case 0x01: case 0x02: case 0x03: case 0x04: case 0x05: case 0x06:
	case 0x07: case 0x08: case 0x16:
		comment.symbol = content[0];
	}
	if (length > 1) {
		switch (content[1]) {
		case 0x08: case 0x0a: case 0x1e:
		case 0x0b: case 0x0d: case 0x0e: case 0x0f: case 0x10: case 0x11:
		case 0x12: case 0x13: case 0x20: case 0x24: case 0x28: case 0x2c:
		case 0x84: case 0x8a: case 0x92:
			comment.evaluation = content[1];
		}
	}
	if (length > 2) {
		switch (content[2]) {
		case 0x8c: case 0x8d: case 0x8e: case 0x8f: case 0x90: case 0x91:
			comment.prefix = content[2];
		}
	}
	comments.push_back(comment);
}

errorT CbhAnnotationDecoder::decode_record(GameReturnValue& game,
                                           std::vector<uint32_t> offsets) {
	finished_ = true;
	if (offsets.size() != 1)
		return ERROR_Decode;
	uint32_t annotation_offset = offsets[0];
	// Zero is the index sentinel for a game without annotations.
	if (annotation_offset == 0)
		return OK;
	if (annotation_offset < ANNOTATION_HEADER_SIZE ||
	    annotation_offset > stream_.size() ||
	    stream_.size() - annotation_offset < 14 ||
	    stream_.pubseekpos(uint64_t(annotation_offset) + 10) == std::streampos(-1))
		return ERROR_Decode;

	// Read number of bytes for annotations in this game (4 bytes)
	char ls[4];
	if (stream_.sgetn(ls, 4) != 4)
		return ERROR_Decode;
	length_ = static_cast<byte>(ls[0]) << 24 | static_cast<byte>(ls[1]) << 16 |
	          static_cast<byte>(ls[2]) << 8 | static_cast<byte>(ls[3]);

	readBytes_ = 14;
	if (length_ < readBytes_ || length_ > stream_.size() - annotation_offset)
		return ERROR_Decode;

	// Validate the entire frame, not just annotations reached by move playback.
	// Pregame/special move numbers can otherwise hide a corrupt trailing entry.
	for (uint32_t cursor = 14; cursor < length_;) {
		char entry[6];
		if (length_ - cursor < 6 || stream_.sgetn(entry, 6) != 6)
			return ERROR_Decode;
		const byte type = static_cast<byte>(entry[3]);
		const uint32_t entrySize = static_cast<byte>(entry[4]) << 8 |
		                           static_cast<byte>(entry[5]);
		if (entrySize < 6 || entrySize > length_ - cursor)
			return ERROR_Decode;
		const uint32_t payloadSize = entrySize - 6;
		if (((type == 0x02 || type == 0x82) && payloadSize < 2) ||
		    (type == 0x04 && payloadSize % 2 != 0) ||
		    (type == 0x05 && payloadSize % 3 != 0))
			return ERROR_Decode;
		// Entry sizes are 16-bit, so this allocation is bounded independently
		// of the untrusted 32-bit record length.
		std::vector<char> payload(payloadSize);
		if (stream_.sgetn(payload.data(), payloadSize) != payloadSize)
			return ERROR_Decode;
		// Inventory unknown data during framing, even if playback never reaches
		// its move number. Callers must not treat OK as lossless conversion.
		bool supported = type == 0x02 || type == 0x82 || type == 0x03 ||
		                 type == 0x04 || type == 0x05;
		const uint move = static_cast<byte>(entry[0]) << 16 |
		                  static_cast<byte>(entry[1]) << 8 | static_cast<byte>(entry[2]);
		game.rawAnnotations.push_back({move, type, std::string(payload.begin(), payload.end())});
		if ((type == 0x07 || type == 0x21) && move != 0xffffff)
			supported = !timedAnnotation(type, reinterpret_cast<const byte*>(payload.data()), payloadSize).empty();
		if (type == 0x18 || type == 0x22 || type == 0x23)
			supported = !positionAnnotation(type, reinterpret_cast<const byte*>(payload.data()), payloadSize).empty();
		if (type == 0x24 && move == 0xffffff) {
			const auto value = timeControl(reinterpret_cast<const byte*>(payload.data()), payloadSize);
			if (!value.empty()) {
				// Multiple controls cannot be represented by one PGN header.
				for (const auto& tag : game.tags) if (tag.tag == "TimeControl") return ERROR_Decode;
				game.tags.emplace_back("TimeControl", value);
				supported = true;
			}
		}
		// All 1,453 supplied 0x16/0x17 entries independently match the
		// reference WhiteClock/BlackClock header in hundredths of a second.
		// These are FINAL clocks, not per-move clock histories.
		if ((type == 0x16 || type == 0x17) && move == 0xffffff) {
			if (payloadSize != 4) return ERROR_Decode;
			const uint32_t centiseconds = uint32_t(static_cast<byte>(payload[0])) << 24 |
			    uint32_t(static_cast<byte>(payload[1])) << 16 |
			    uint32_t(static_cast<byte>(payload[2])) << 8 | static_cast<byte>(payload[3]);
			// Negative/sentinel clock encodings are not yet verified.
			if (centiseconds < 0x80000000u) {
				const uint32_t seconds = centiseconds / 100;
				std::ostringstream value;
				value << seconds / 3600 << ':' << std::setfill('0') << std::setw(2)
				      << (seconds / 60) % 60 << ':' << std::setw(2) << seconds % 60;
				if (centiseconds % 100) value << '.' << std::setw(2) << centiseconds % 100;
				game.tags.emplace_back(type == 0x16 ? "WhiteClock" : "BlackClock", value.str());
				supported = true;
			}
		}
		if (type == 0x03) {
			std::vector<Comment> decoded;
			decodeSymbol(decoded, reinterpret_cast<const byte*>(payload.data()), payloadSize, WHITE);
			if (payloadSize > 3 || decoded.empty()) supported = false;
			else {
				const auto& symbols = std::get<SymbolComment>(decoded.front());
				const byte values[] = {symbols.symbol, symbols.evaluation, symbols.prefix};
				for (uint32_t i = 0; i < payloadSize; ++i)
					if (values[i] != static_cast<byte>(payload[i])) supported = false;
			}
		}
		if (!supported) {
			const uint move = static_cast<byte>(entry[0]) << 16 |
			                  static_cast<byte>(entry[1]) << 8 | static_cast<byte>(entry[2]);
			game.unsupportedAnnotations.push_back({move, type, std::string(payload.begin(), payload.end())});
		}
		cursor += entrySize;
	}
	if (stream_.pubseekpos(uint64_t(annotation_offset) + 14) == std::streampos(-1))
		return ERROR_Decode;

	// Read position in game (3 bytes) big endian (mistake on talkchess?)
	if (readBytes_ < length_) {
		char ps[3];
		if (length_ - readBytes_ < 3 || stream_.sgetn(ps, 3) != 3)
			return ERROR_Decode;
		move_number_ = static_cast<byte>(ps[0]) << 16 |
		               static_cast<byte>(ps[1]) << 8 | static_cast<byte>(ps[2]);
		readBytes_ += 3;
		finished_ = false;
	} else {
		finished_ = true;
	}

	return OK;
}

errorT CbhAnnotationDecoder::addAnnotations(std::vector<Comment>& comments,
                                          uint32_t move_number,
                                          colorT sideToMove) {
	if (finished_ || move_number != move_number_) {
		return OK;
	}

	while (readBytes_ < length_ && move_number_ == move_number) {

		// Read type of annotation (1 byte)
		if (length_ - readBytes_ < 3)
			return ERROR_Decode;
		const auto typeValue = stream_.sbumpc();
		if (typeValue == std::char_traits<char>::eof())
			return ERROR_Decode;
		byte type = static_cast<byte>(typeValue);

		// Read length of annotation (2 bytes, little endian) including 6
		// previous bytes
		char al[2];
		if (stream_.sgetn(al, 2) != 2)
			return ERROR_Decode;
		const uint32_t encodedSize = static_cast<byte>(al[0]) << 8 | static_cast<byte>(al[1]);
		if (encodedSize < 6 || encodedSize - 6 > length_ - readBytes_ - 3)
			return ERROR_Decode;
		const uint32_t size = encodedSize - 6;
		if (((type == 0x02 || type == 0x82) && size < 2) ||
		    (type == 0x04 && size % 2 != 0) ||
		    (type == 0x05 && size % 3 != 0))
			return ERROR_Decode;

		std::vector<char> contentStorage(static_cast<size_t>(size) + 1);
		char* content = contentStorage.data();
		if (stream_.sgetn(content, size) != size)
			return ERROR_Decode;
		content[size] = 0;
		readBytes_ += size + 3;

		switch (type) {
		case 0x02: // text after move
		{
			langT lang = static_cast<byte>(content[0]) << 8 |
			             static_cast<byte>(
			                 content[1]); // big Endian (mistake on talkchess?)
			const char* text = content + 2;
			comments.push_back(TextAfterComment(lang, text));
			break;
		}
		case 0x03: // symbol
		{
			decodeSymbol(comments, reinterpret_cast<byte*>(content), size,
			             sideToMove);
			break;
		}
		case 0x04: // squares
			decodeSquares(comments, content, size);
			break;
		case 0x05: // arrows
			decodeArrows(comments, content, size);
			break;
		case 0x07: // elapsed move time, not remaining clock
		case 0x21: // engine evaluation
		{
			const auto value = timedAnnotation(type, reinterpret_cast<const byte*>(content), size);
			if (!value.empty()) comments.push_back(TextAfterComment(0, value));
			break;
		}
		case 0x09: // training annotation
			break;
		case 0x10: // sound
			break;
		case 0x11: // picture
			break;
		case 0x13: // game quotation
			break;
		case 0x14: // pawn structure
			break;
		case 0x15: // piece path
			break;
		case 0x18: // critical position
		case 0x22: // medal
		case 0x23: // variation color
		{
			const auto value = positionAnnotation(type, reinterpret_cast<const byte*>(content), size);
			if (!value.empty()) comments.push_back(TextAfterComment(0, value));
			break;
		}
		case 0x19: // correspondence move
			break;
		case 0x24: // Time control
		{
			const auto value = timeControl(reinterpret_cast<const byte*>(content), size);
			if (move_number == 0xffffff && !value.empty())
				comments.push_back(TextAfterComment(0, "Time control: " + value + " seconds"));
			break;
		}
		case 0x61: // correspondence header
			break;
		case 0x82: // text before move
		{
			langT lang = static_cast<byte>(content[0]) << 8 |
			             static_cast<byte>(
			                 content[1]); // big Endian (mistake on talkchess?)
			const char* text = content + 2;
			comments.push_back(TextBeforeComment(lang, text));
			break;
		}
		default: // unknown annotation type
			break;
		}

		if (readBytes_ < length_) {
			// Read position in game (3 bytes) big endian (mistake on
			// talkchess?)
			char ps[3];
			if (length_ - readBytes_ < 3 || stream_.sgetn(ps, 3) != 3)
				return ERROR_Decode;
			move_number_ = static_cast<byte>(ps[0]) << 16 |
			               static_cast<byte>(ps[1]) << 8 |
			               static_cast<byte>(ps[2]);
			readBytes_ += 3;
		} else {
			finished_ = true;
		}
	}
	return OK;
}
