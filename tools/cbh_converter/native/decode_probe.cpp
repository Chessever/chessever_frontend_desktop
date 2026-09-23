// Evaluation only: exercise libcbh without touching ChessEver or source databases.
#include "cbh.h"
#include <fstream>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <type_traits>

std::string jsonBytes(const std::string& value) {
    std::ostringstream out; out << '"';
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32 || c >= 127) out << "\\u00" << std::hex << std::setw(2) << std::setfill('0') << unsigned(c);
        else out << c;
    }
    out << '"'; return out.str();
}
void commentJson(std::ostream& out, const Comment& comment) {
    std::visit([&](const auto& c) {
        using T = std::decay_t<decltype(c)>;
        if constexpr (std::is_same_v<T, TextBeforeComment> || std::is_same_v<T, TextAfterComment>) {
            out << "{\"kind\":" << jsonBytes(std::is_same_v<T, TextBeforeComment> ? "before" : "after")
                << ",\"language\":" << c.lang << ",\"textBytes\":" << jsonBytes(c.text) << '}';
        } else if constexpr (std::is_same_v<T, ArrowComment>) {
            out << "{\"kind\":\"arrow\",\"from\":" << unsigned(c.from) << ",\"to\":" << unsigned(c.to) << ",\"color\":" << jsonBytes(c.color) << '}';
        } else if constexpr (std::is_same_v<T, SquareComment>) {
            out << "{\"kind\":\"square\",\"square\":" << unsigned(c.sq) << ",\"color\":" << jsonBytes(c.color) << '}';
        } else {
            out << "{\"kind\":\"symbols\",\"symbol\":" << unsigned(c.symbol) << ",\"evaluation\":" << unsigned(c.evaluation) << ",\"prefix\":" << unsigned(c.prefix) << '}';
        }
    }, comment);
}
int main(int argc, char** argv) {
    if (argc != 3) { std::cerr << "usage: decode_probe source.cbh new-output.jsonl\n"; return 64; }
    if (std::filesystem::exists(argv[2])) { std::cerr << "Output exists\n"; return 65; }
    CbhCodec codec;
    auto error = codec.open(argv[1]);
    if (error != OK) { std::cerr << "open_error=" << error << '\n'; return 2; }
    std::ofstream out(argv[2], std::ios::binary);
    out.exceptions(std::ios::badbit | std::ios::failbit);
    out << "{\"records\":" << codec.numGames() << "}\n";
    size_t failures = 0;
    for (size_t i = 0; i < codec.numGames(); ++i) {
        GameReturnValue game{};
        error = codec.parseNext(game);
        if (error != OK) ++failures;
        out << "{\"record\":" << i << ",\"error\":" << error;
        if (error == OK) {
            if (game.eco) {
                const auto code = (game.eco - 1) / 131;
                std::ostringstream eco;
                eco << char('A' + code / 100) << std::setw(2) << std::setfill('0') << code % 100;
                out << ",\"eco\":" << jsonBytes(eco.str());
            }
            out << ",\"eventDate\":[" << game.eventDate.year << ',' << game.eventDate.month << ',' << game.eventDate.day << ']';
            out << ",\"chess960\":" << (game.chess960 ? "true" : "false")
                << ",\"fen\":" << jsonBytes(game.startFen)
                << ",\"white\":" << jsonBytes(game.whiteName + (game.whiteFirstName.empty() ? "" : ", " + game.whiteFirstName))
                << ",\"black\":" << jsonBytes(game.blackName + (game.blackFirstName.empty() ? "" : ", " + game.blackFirstName))
                << ",\"event\":" << jsonBytes(game.eventTitle) << ",\"site\":" << jsonBytes(game.eventPlace)
                << ",\"date\":[" << game.gameDate.year << ',' << game.gameDate.month << ',' << game.gameDate.day << ']'
                << ",\"round\":" << unsigned(game.round) << ",\"subround\":" << unsigned(game.subround)
                << ",\"result\":" << unsigned(game.result) << ",\"whiteElo\":" << game.whiteElo << ",\"blackElo\":" << game.blackElo
                << ",\"tags\":[";
            bool first = true;
            for (const auto& tag : game.tags) { if (!first) out << ','; first = false; out << '[' << jsonBytes(tag.tag) << ',' << jsonBytes(tag.value) << ']'; }
            out << "],\"unsupportedAnnotations\":["; first = true;
            for (const auto& a : game.unsupportedAnnotations) {
                if (!first) out << ','; first = false;
                out << "{\"move\":" << a.move << ",\"type\":" << unsigned(a.type)
                    << ",\"payloadBytes\":" << jsonBytes(a.payload) << '}';
            }
            out << "],\"unconsumedAnnotations\":" << (game.unconsumedAnnotations ? "true" : "false")
                << ",\"rawAnnotations\":["; first = true;
            for (const auto& a : game.rawAnnotations) {
                if (!first) out << ','; first = false;
                out << "{\"move\":" << a.move << ",\"type\":" << unsigned(a.type)
                    << ",\"payloadBytes\":" << jsonBytes(a.payload) << '}';
            }
            out << "],\"pregameComments\":["; first = true;
            for (const auto& c : game.pregameComments) { if (!first) out << ','; first = false; commentJson(out, c); }
            out << "],\"moves\":["; first = true;
            for (const auto& move : game.annotatedMoves) {
                if (!first) out << ','; first = false;
                out << "{\"from\":" << unsigned(move.from) << ",\"to\":" << unsigned(move.to) << ",\"promotion\":" << unsigned(move.promote) << ",\"comments\":[";
                bool fc = true;
                for (const auto& c : move.comments) { if (!fc) out << ','; fc = false; commentJson(out, c); }
                out << "]}";
            }
            out << ']';
        }
        out << "}\n";
    }
    out.flush(); out.close();
    std::cerr << "records=" << codec.numGames() << " failed=" << failures << '\n';
    return failures ? 3 : 0;
}
