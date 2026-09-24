extends RefCounted
class_name UberbotOpenings

# UberbotOpenings — a hard-coded OPENING BOOK for UberBot.
#
# WHY: the search plays the same handful of openings every game. OPENING_VARIETY_CP
# in uber_bot.gd randomises among root moves within 35cp of the best, but the
# piece-square table rates only a few opening moves that closely, so the pool is
# usually 2-3 moves wide. This book replaces the first few plies outright with real
# opening theory, giving 9 different first moves as White and up to 10 replies to
# 1.e4 as Black.
#
# HOW IT MATCHES: the book is indexed by POSITION SIGNATURE, not by move number, so
# it does not need a move history. At _init every line is replayed from the standard
# start position and each resulting layout is filed under its signature along with the
# move that follows. At runtime the bot signs the live board and looks it up. Lines
# that transpose into each other therefore share an entry automatically.
#
# HOW IT DEGRADES: any position not in the index returns null and the bot searches as
# before. That covers everything Uberchess can do that normal chess cannot — a Cheat
# relocation, a Teleport, a revived piece, a Super Pawn (signed as "S", which
# deliberately matches no book entry) — as well as the human simply playing something
# offbeat. The book can never fire on a position it does not recognise exactly, and
# every move it proposes is re-checked against game.get_safe_moves() before use.
#
# COORDINATES: moves are 4 digits, from_x from_y to_x to_y, with x = file (a=0..h=7)
# and y = 8 - rank (so White's back rank is y=7). Castling is stored as the KING move
# only; _apply_move detects the two-file king step and shifts the rook to match.
#
# EDITING: add a line by appending {"name", "san", "moves"} below. The "san" field is
# documentation only — nothing reads it — but keep it accurate, it is how the moves
# were generated and verified. All 96 lines here were replayed through a chess engine
# to confirm every move is legal from the opening position.

# Every line is capped at this many plies; past it the bot searches normally.
const MAX_BOOK_PLY := 10

const _BACK_RANK := ["R", "N", "B", "Q", "K", "B", "N", "R"]
const _TYPE_CODE := {
	"Pawn": "P", "Knight": "N", "Bishop": "B",
	"Rook": "R", "Queen": "Q", "King": "K",
}

var LINES := [
	{"name": "Ruy Lopez, Morphy Defence",
	 "san": "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7",
	 "moves": "4644 4143 6755 1022 5713 0102 1304 6052 4767 5041"},
	{"name": "Ruy Lopez, Berlin Defence",
	 "san": "e4 e5 Nf3 Nc6 Bb5 Nf6 O-O Nxe4 d4 Nd6",
	 "moves": "4644 4143 6755 1022 5713 6052 4767 5244 3634 4432"},
	{"name": "Ruy Lopez, Exchange",
	 "san": "e4 e5 Nf3 Nc6 Bb5 a6 Bxc6 dxc6 O-O f6",
	 "moves": "4644 4143 6755 1022 5713 0102 1322 3122 4767 5152"},
	{"name": "Italian Game, Giuoco Piano",
	 "san": "e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6 d4 exd4",
	 "moves": "4644 4143 6755 1022 5724 5023 2625 6052 3634 4334"},
	{"name": "Italian Game, Giuoco Pianissimo",
	 "san": "e4 e5 Nf3 Nc6 Bc4 Bc5 d3 Nf6 O-O d6",
	 "moves": "4644 4143 6755 1022 5724 5023 3635 6052 4767 3132"},
	{"name": "Two Knights Defence",
	 "san": "e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5 d5 exd5 Na5",
	 "moves": "4644 4143 6755 1022 5724 6052 5563 3133 4433 2203"},
	{"name": "Evans Gambit",
	 "san": "e4 e5 Nf3 Nc6 Bc4 Bc5 b4 Bxb4 c3 Ba5",
	 "moves": "4644 4143 6755 1022 5724 5023 1614 2314 2625 1403"},
	{"name": "Scotch Game",
	 "san": "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Bc5 Be3 Qf6",
	 "moves": "4644 4143 6755 1022 3634 4334 5534 5023 2745 3052"},
	{"name": "Scotch Gambit",
	 "san": "e4 e5 Nf3 Nc6 d4 exd4 Bc4 Bc5 c3 Nf6",
	 "moves": "4644 4143 6755 1022 3634 4334 5724 5023 2625 6052"},
	{"name": "Four Knights Game",
	 "san": "e4 e5 Nf3 Nc6 Nc3 Nf6 Bb5 Bb4 O-O O-O",
	 "moves": "4644 4143 6755 1022 1725 6052 5713 5014 4767 4060"},
	{"name": "Petrov's Defence",
	 "san": "e4 e5 Nf3 Nf6 Nxe5 d6 Nf3 Nxe4 d4 d5",
	 "moves": "4644 4143 6755 6052 5543 3132 4355 5244 3634 3233"},
	{"name": "Philidor Defence",
	 "san": "e4 e5 Nf3 d6 d4 exd4 Nxd4 Nf6 Nc3 Be7",
	 "moves": "4644 4143 6755 3132 3634 4334 5534 6052 1725 5041"},
	{"name": "Ponziani Opening",
	 "san": "e4 e5 Nf3 Nc6 c3 Nf6 d4 Nxe4 d5 Ne7",
	 "moves": "4644 4143 6755 1022 2625 6052 3634 5244 3433 2241"},
	{"name": "King's Gambit Accepted",
	 "san": "e4 e5 f4 exf4 Nf3 g5 h4 g4 Ne5 Nf6",
	 "moves": "4644 4143 5654 4354 6755 6163 7674 6364 5543 6052"},
	{"name": "King's Gambit Declined",
	 "san": "e4 e5 f4 Bc5 Nf3 d6 Nc3 Nf6 Bc4 Nc6",
	 "moves": "4644 4143 5654 5023 6755 3132 1725 6052 5724 1022"},
	{"name": "Vienna Game, Falkbeer",
	 "san": "e4 e5 Nc3 Nf6 f4 d5 fxe5 Nxe4 Nf3 Be7",
	 "moves": "4644 4143 1725 6052 5654 3133 5443 5244 6755 5041"},
	{"name": "Vienna Game, Mieses",
	 "san": "e4 e5 Nc3 Nf6 g3 d5 exd5 Nxd5 Bg2 Nxc3",
	 "moves": "4644 4143 1725 6052 6665 3133 4433 5233 5766 3325"},
	{"name": "Bishop's Opening",
	 "san": "e4 e5 Bc4 Nf6 d3 c6 Nf3 d5 Bb3 Bd6",
	 "moves": "4644 4143 5724 6052 3635 2122 6755 3133 2415 5032"},
	{"name": "Centre Game",
	 "san": "e4 e5 d4 exd4 Qxd4 Nc6 Qe3 Nf6 Nc3 Bb4",
	 "moves": "4644 4143 3634 4334 3734 1022 3445 6052 1725 5014"},
	{"name": "Sicilian, Najdorf",
	 "san": "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6",
	 "moves": "4644 2123 6755 3132 3634 2334 5534 6052 1725 0102"},
	{"name": "Sicilian, Dragon",
	 "san": "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6",
	 "moves": "4644 2123 6755 3132 3634 2334 5534 6052 1725 6162"},
	{"name": "Sicilian, Classical",
	 "san": "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 Nc6",
	 "moves": "4644 2123 6755 3132 3634 2334 5534 6052 1725 1022"},
	{"name": "Sicilian, Scheveningen",
	 "san": "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 e6",
	 "moves": "4644 2123 6755 3132 3634 2334 5534 6052 1725 4142"},
	{"name": "Sicilian, Sveshnikov",
	 "san": "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 Nf6 Nc3 e5",
	 "moves": "4644 2123 6755 1022 3634 2334 5534 6052 1725 4143"},
	{"name": "Sicilian, Accelerated Dragon",
	 "san": "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 g6 Nc3 Bg7",
	 "moves": "4644 2123 6755 1022 3634 2334 5534 6162 1725 5061"},
	{"name": "Sicilian, Taimanov",
	 "san": "e4 c5 Nf3 e6 d4 cxd4 Nxd4 Nc6 Nc3 Qc7",
	 "moves": "4644 2123 6755 4142 3634 2334 5534 1022 1725 3021"},
	{"name": "Sicilian, Kan",
	 "san": "e4 c5 Nf3 e6 d4 cxd4 Nxd4 a6 Nc3 Qc7",
	 "moves": "4644 2123 6755 4142 3634 2334 5534 0102 1725 3021"},
	{"name": "Sicilian, Alapin",
	 "san": "e4 c5 c3 d5 exd5 Qxd5 d4 Nf6 Nf3 e6",
	 "moves": "4644 2123 2625 3133 4433 3033 3634 6052 6755 4142"},
	{"name": "Sicilian, Closed",
	 "san": "e4 c5 Nc3 Nc6 g3 g6 Bg2 Bg7 d3 d6",
	 "moves": "4644 2123 1725 1022 6665 6162 5766 5061 3635 3132"},
	{"name": "Sicilian, Smith-Morra Gambit",
	 "san": "e4 c5 d4 cxd4 c3 dxc3 Nxc3 Nc6 Nf3 d6",
	 "moves": "4644 2123 3634 2334 2625 3425 1725 1022 6755 3132"},
	{"name": "Sicilian, Grand Prix Attack",
	 "san": "e4 c5 Nc3 Nc6 f4 g6 Nf3 Bg7 Bc4 e6",
	 "moves": "4644 2123 1725 1022 5654 6162 6755 5061 5724 4142"},
	{"name": "French, Winawer",
	 "san": "e4 e6 d4 d5 Nc3 Bb4 e5 c5 a3 Bxc3+",
	 "moves": "4644 4142 3634 3133 1725 5014 4443 2123 0605 1425"},
	{"name": "French, Classical",
	 "san": "e4 e6 d4 d5 Nc3 Nf6 Bg5 Be7 e5 Nfd7",
	 "moves": "4644 4142 3634 3133 1725 6052 2763 5041 4443 5231"},
	{"name": "French, Tarrasch",
	 "san": "e4 e6 d4 d5 Nd2 Nf6 e5 Nfd7 Bd3 c5",
	 "moves": "4644 4142 3634 3133 1736 6052 4443 5231 5735 2123"},
	{"name": "French, Advance",
	 "san": "e4 e6 d4 d5 e5 c5 c3 Nc6 Nf3 Qb6",
	 "moves": "4644 4142 3634 3133 4443 2123 2625 1022 6755 3012"},
	{"name": "French, Exchange",
	 "san": "e4 e6 d4 d5 exd5 exd5 Nf3 Nf6 Bd3 Bd6",
	 "moves": "4644 4142 3634 3133 4433 4233 6755 6052 5735 5032"},
	{"name": "Caro-Kann, Classical",
	 "san": "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5 Ng3 Bg6",
	 "moves": "4644 2122 3634 3133 1725 3344 2544 2053 4465 5362"},
	{"name": "Caro-Kann, Advance",
	 "san": "e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5",
	 "moves": "4644 2122 3634 3133 4443 2053 6755 4142 5746 2223"},
	{"name": "Caro-Kann, Exchange",
	 "san": "e4 c6 d4 d5 exd5 cxd5 Bd3 Nc6 c3 Nf6",
	 "moves": "4644 2122 3634 3133 4433 2233 5735 1022 2625 6052"},
	{"name": "Caro-Kann, Panov Attack",
	 "san": "e4 c6 d4 d5 exd5 cxd5 c4 Nf6 Nc3 e6",
	 "moves": "4644 2122 3634 3133 4433 2233 2624 6052 1725 4142"},
	{"name": "Scandinavian, Main Line",
	 "san": "e4 d5 exd5 Qxd5 Nc3 Qa5 d4 Nf6 Nf3 c6",
	 "moves": "4644 3133 4433 3033 1725 3303 3634 6052 6755 2122"},
	{"name": "Scandinavian, Modern",
	 "san": "e4 d5 exd5 Nf6 d4 Nxd5 Nf3 g6 Be2 Bg7",
	 "moves": "4644 3133 4433 6052 3634 5233 6755 6162 5746 5061"},
	{"name": "Alekhine's Defence",
	 "san": "e4 Nf6 e5 Nd5 d4 d6 Nf3 g6 Bc4 Nb6",
	 "moves": "4644 6052 4443 5233 3634 3132 6755 6162 5724 3312"},
	{"name": "Pirc Defence",
	 "san": "e4 d6 d4 Nf6 Nc3 g6 Nf3 Bg7 Be2 O-O",
	 "moves": "4644 3132 3634 6052 1725 6162 6755 5061 5746 4060"},
	{"name": "Modern Defence",
	 "san": "e4 g6 d4 Bg7 Nc3 d6 f4 Nf6 Nf3 O-O",
	 "moves": "4644 6162 3634 5061 1725 3132 5654 6052 6755 4060"},
	{"name": "Nimzowitsch Defence",
	 "san": "e4 Nc6 Nf3 d6 d4 Nf6 Nc3 Bg4 Be3 e6",
	 "moves": "4644 1022 6755 3132 3634 6052 1725 2064 2745 4142"},
	{"name": "Owen's Defence",
	 "san": "e4 b6 d4 Bb7 Nc3 e6 Nf3 Nf6 Bd3 Bb4",
	 "moves": "4644 1112 3634 2011 1725 4142 6755 6052 5735 5014"},
	{"name": "Queen's Gambit Declined",
	 "san": "d4 d5 c4 e6 Nc3 Nf6 Bg5 Be7 e3 O-O",
	 "moves": "3634 3133 2624 4142 1725 6052 2763 5041 4645 4060"},
	{"name": "QGD, Exchange Variation",
	 "san": "d4 d5 c4 e6 cxd5 exd5 Nc3 Nf6 Bg5 Be7",
	 "moves": "3634 3133 2624 4142 2433 4233 1725 6052 2763 5041"},
	{"name": "Queen's Gambit Accepted",
	 "san": "d4 d5 c4 dxc4 Nf3 Nf6 e3 e6 Bxc4 c5",
	 "moves": "3634 3133 2624 3324 6755 6052 4645 4142 5724 2123"},
	{"name": "Slav Defence",
	 "san": "d4 d5 c4 c6 Nf3 Nf6 Nc3 dxc4 a4 Bf5",
	 "moves": "3634 3133 2624 2122 6755 6052 1725 3324 0604 2053"},
	{"name": "Semi-Slav Defence",
	 "san": "d4 d5 c4 c6 Nf3 Nf6 Nc3 e6 e3 Nbd7",
	 "moves": "3634 3133 2624 2122 6755 6052 1725 4142 4645 1031"},
	{"name": "Slav, Exchange Variation",
	 "san": "d4 d5 c4 c6 cxd5 cxd5 Nc3 Nf6 Nf3 Nc6",
	 "moves": "3634 3133 2624 2122 2433 2233 1725 6052 6755 1022"},
	{"name": "Chigorin Defence",
	 "san": "d4 d5 c4 Nc6 Nc3 dxc4 Nf3 Nf6 e4 Bg4",
	 "moves": "3634 3133 2624 1022 1725 3324 6755 6052 4644 2064"},
	{"name": "Albin Counter-Gambit",
	 "san": "d4 d5 c4 e5 dxe5 d4 Nf3 Nc6 g3 Bg4",
	 "moves": "3634 3133 2624 4143 3443 3334 6755 1022 6665 2064"},
	{"name": "Tarrasch Defence",
	 "san": "d4 d5 c4 e6 Nc3 c5 cxd5 exd5 Nf3 Nc6",
	 "moves": "3634 3133 2624 4142 1725 2123 2433 4233 6755 1022"},
	{"name": "Colle System",
	 "san": "d4 d5 Nf3 Nf6 e3 e6 Bd3 c5 c3 Nc6",
	 "moves": "3634 3133 6755 6052 4645 4142 5735 2123 2625 1022"},
	{"name": "London System",
	 "san": "d4 d5 Bf4 Nf6 e3 e6 Nf3 Bd6 Bg3 O-O",
	 "moves": "3634 3133 2754 6052 4645 4142 6755 5032 5465 4060"},
	{"name": "London System vs Indian",
	 "san": "d4 Nf6 Nf3 d5 Bf4 c5 e3 Nc6 c3 Qb6",
	 "moves": "3634 6052 6755 3133 2754 2123 4645 1022 2625 3012"},
	{"name": "Torre Attack",
	 "san": "d4 Nf6 Nf3 e6 Bg5 c5 e3 Be7 Nbd2 O-O",
	 "moves": "3634 6052 6755 4142 2763 2123 4645 5041 1736 4060"},
	{"name": "Trompowsky Attack",
	 "san": "d4 Nf6 Bg5 Ne4 Bf4 d5 e3 c5 Bd3 Nc6",
	 "moves": "3634 6052 2763 5244 6354 3133 4645 2123 5735 1022"},
	{"name": "Nimzo-Indian, Rubinstein",
	 "san": "d4 Nf6 c4 e6 Nc3 Bb4 e3 O-O Bd3 d5",
	 "moves": "3634 6052 2624 4142 1725 5014 4645 4060 5735 3133"},
	{"name": "Nimzo-Indian, Classical",
	 "san": "d4 Nf6 c4 e6 Nc3 Bb4 Qc2 O-O a3 Bxc3+",
	 "moves": "3634 6052 2624 4142 1725 5014 3726 4060 0605 1425"},
	{"name": "Queen's Indian Defence",
	 "san": "d4 Nf6 c4 e6 Nf3 b6 g3 Ba6 b3 Bb4+",
	 "moves": "3634 6052 2624 4142 6755 1112 6665 2002 1615 5014"},
	{"name": "Bogo-Indian Defence",
	 "san": "d4 Nf6 c4 e6 Nf3 Bb4+ Bd2 Qe7 g3 Nc6",
	 "moves": "3634 6052 2624 4142 6755 5014 2736 3041 6665 1022"},
	{"name": "Catalan Opening",
	 "san": "d4 Nf6 c4 e6 g3 d5 Bg2 Be7 Nf3 O-O",
	 "moves": "3634 6052 2624 4142 6665 3133 5766 5041 6755 4060"},
	{"name": "King's Indian, Classical",
	 "san": "d4 Nf6 c4 g6 Nc3 Bg7 e4 d6 Nf3 O-O",
	 "moves": "3634 6052 2624 6162 1725 5061 4644 3132 6755 4060"},
	{"name": "King's Indian, Fianchetto",
	 "san": "d4 Nf6 c4 g6 Nf3 Bg7 g3 O-O Bg2 d6",
	 "moves": "3634 6052 2624 6162 6755 5061 6665 4060 5766 3132"},
	{"name": "Gruenfeld, Exchange",
	 "san": "d4 Nf6 c4 g6 Nc3 d5 cxd5 Nxd5 e4 Nxc3",
	 "moves": "3634 6052 2624 6162 1725 3133 2433 5233 4644 3325"},
	{"name": "Gruenfeld, Russian System",
	 "san": "d4 Nf6 c4 g6 Nc3 d5 Nf3 Bg7 Qb3 dxc4",
	 "moves": "3634 6052 2624 6162 1725 3133 6755 5061 3715 3324"},
	{"name": "Modern Benoni",
	 "san": "d4 Nf6 c4 c5 d5 e6 Nc3 exd5 cxd5 d6",
	 "moves": "3634 6052 2624 2123 3433 4142 1725 4233 2433 3132"},
	{"name": "Benko Gambit",
	 "san": "d4 Nf6 c4 c5 d5 b5 cxb5 a6 bxa6 Bxa6",
	 "moves": "3634 6052 2624 2123 3433 1113 2413 0102 1302 2002"},
	{"name": "Budapest Gambit",
	 "san": "d4 Nf6 c4 e5 dxe5 Ng4 Bf4 Nc6 Nf3 Bb4+",
	 "moves": "3634 6052 2624 4143 3443 5264 2754 1022 6755 5014"},
	{"name": "Old Indian Defence",
	 "san": "d4 Nf6 c4 d6 Nc3 e5 Nf3 Nbd7 e4 Be7",
	 "moves": "3634 6052 2624 3132 1725 4143 6755 1031 4644 5041"},
	{"name": "Dutch, Leningrad",
	 "san": "d4 f5 g3 Nf6 Bg2 g6 Nf3 Bg7 O-O O-O",
	 "moves": "3634 5153 6665 6052 5766 6162 6755 5061 4767 4060"},
	{"name": "Dutch, Stonewall",
	 "san": "d4 f5 g3 Nf6 Bg2 e6 Nf3 d5 O-O Bd6",
	 "moves": "3634 5153 6665 6052 5766 4142 6755 3133 4767 5032"},
	{"name": "Dutch, Classical",
	 "san": "d4 f5 c4 Nf6 Nc3 e6 Nf3 Be7 g3 O-O",
	 "moves": "3634 5153 2624 6052 1725 4142 6755 5041 6665 4060"},
	{"name": "Modern Defence vs d4",
	 "san": "d4 g6 c4 Bg7 Nc3 d6 e4 Nf6 Nf3 O-O",
	 "moves": "3634 6162 2624 5061 1725 3132 4644 6052 6755 4060"},
	{"name": "English, Symmetrical",
	 "san": "c4 c5 Nc3 Nc6 g3 g6 Bg2 Bg7 Nf3 Nf6",
	 "moves": "2624 2123 1725 1022 6665 6162 5766 5061 6755 6052"},
	{"name": "English, Reversed Sicilian",
	 "san": "c4 e5 Nc3 Nf6 Nf3 Nc6 g3 d5 cxd5 Nxd5",
	 "moves": "2624 4143 1725 6052 6755 1022 6665 3133 2433 5233"},
	{"name": "English, Four Knights",
	 "san": "c4 e5 Nc3 Nf6 Nf3 Nc6 e3 Bb4 Qc2 O-O",
	 "moves": "2624 4143 1725 6052 6755 1022 4645 5014 3726 4060"},
	{"name": "English, Anglo-Indian",
	 "san": "c4 Nf6 Nc3 e6 Nf3 d5 d4 Be7 Bg5 O-O",
	 "moves": "2624 6052 1725 4142 6755 3133 3634 5041 2763 4060"},
	{"name": "English, Mikenas Attack",
	 "san": "c4 Nf6 Nc3 e6 e4 d5 e5 d4 exf6 dxc3",
	 "moves": "2624 6052 1725 4142 4644 3133 4443 3334 4352 3425"},
	{"name": "English, Agincourt Defence",
	 "san": "c4 e6 Nf3 d5 g3 Nf6 Bg2 Be7 O-O O-O",
	 "moves": "2624 4142 6755 3133 6665 6052 5766 5041 4767 4060"},
	{"name": "Reti Opening",
	 "san": "Nf3 d5 c4 e6 g3 Nf6 Bg2 Be7 O-O O-O",
	 "moves": "6755 3133 2624 4142 6665 6052 5766 5041 4767 4060"},
	{"name": "Reti, Slav-like",
	 "san": "Nf3 d5 c4 c6 e3 Nf6 Nc3 e6 b3 Be7",
	 "moves": "6755 3133 2624 2122 4645 6052 1725 4142 1615 5041"},
	{"name": "King's Indian Attack",
	 "san": "Nf3 d5 g3 Nf6 Bg2 e6 O-O Be7 d3 O-O",
	 "moves": "6755 3133 6665 6052 5766 4142 4767 5041 3635 4060"},
	{"name": "Zukertort, Double Fianchetto",
	 "san": "Nf3 Nf6 g3 g6 Bg2 Bg7 O-O O-O d3 d6",
	 "moves": "6755 6052 6665 6162 5766 5061 4767 4060 3635 3132"},
	{"name": "Benko / Hungarian Opening",
	 "san": "g3 d5 Bg2 Nf6 Nf3 e6 O-O Be7 d3 O-O",
	 "moves": "6665 3133 5766 6052 6755 4142 4767 5041 3635 4060"},
	{"name": "Hungarian, King's Fianchetto",
	 "san": "g3 e5 Bg2 d5 d3 Nf6 Nf3 Nc6 O-O Be7",
	 "moves": "6665 4143 5766 3133 3635 6052 6755 1022 4767 5041"},
	{"name": "Nimzo-Larsen Attack",
	 "san": "b3 e5 Bb2 Nc6 e3 Nf6 Bb5 Bd6 Na3 O-O",
	 "moves": "1615 4143 2716 1022 4645 6052 5713 5032 1705 4060"},
	{"name": "Nimzo-Larsen vs d5",
	 "san": "b3 d5 Bb2 Nf6 e3 e6 Nf3 Be7 c4 O-O",
	 "moves": "1615 3133 2716 6052 4645 4142 6755 5041 2624 4060"},
	{"name": "Bird's Opening",
	 "san": "f4 d5 Nf3 Nf6 e3 g6 Be2 Bg7 O-O O-O",
	 "moves": "5654 3133 6755 6052 4645 6162 5746 5061 4767 4060"},
	{"name": "Bird's, From's Gambit",
	 "san": "f4 e5 fxe5 d6 exd6 Bxd6 Nf3 g5 d4 g4",
	 "moves": "5654 4143 5443 3132 4332 5032 6755 6163 3634 6364"},
	{"name": "Sokolsky / Polish Opening",
	 "san": "b4 e5 Bb2 Bxb4 Bxe5 Nf6 c4 O-O Nf3 d5",
	 "moves": "1614 4143 2716 5014 1643 6052 2624 4060 6755 3133"},
	{"name": "Dunst Opening",
	 "san": "Nc3 d5 d4 Nf6 Bf4 a6 e3 e6 Nf3 c5",
	 "moves": "1725 3133 3634 6052 2754 0102 4645 4142 6755 2123"},
]

# Position signature -> Array of {"from": Vector2, "to": Vector2, "name": String}.
var _index := {}
var rng := RandomNumberGenerator.new()

func _init() -> void:
	rng.randomize()
	_build_index()

# Replays every line from the start position, filing each intermediate layout under its
# signature with the move that continues the line. Runs once, ~96 lines x 10 plies.
func _build_index() -> void:
	for line in LINES:
		var board := _start_board()
		var toks: PackedStringArray = String(line["moves"]).split(" ", false)
		for i in range(mini(toks.size(), MAX_BOOK_PLY)):
			var tok: String = toks[i]
			var from_pos := Vector2(float(tok.substr(0, 1).to_int()), float(tok.substr(1, 1).to_int()))
			var to_pos := Vector2(float(tok.substr(2, 1).to_int()), float(tok.substr(3, 1).to_int()))
			# White moves on even plies. Side-to-move is part of the signature so a layout
			# can never be matched for the wrong player.
			var sig := _sign(board, "w" if i % 2 == 0 else "b")
			var bucket: Array = _index.get(sig, [])
			var dup := false
			for e in bucket:
				if e["from"] == from_pos and e["to"] == to_pos:
					dup = true
					break
			if not dup:
				bucket.append({"from": from_pos, "to": to_pos, "name": line["name"]})
				_index[sig] = bucket
			_apply_move(board, from_pos, to_pos)

# The book's own reply for the live position, or null if the position is off-book.
# Returns {"from": Vector2, "to": Vector2, "name": String}.
func book_move(game, color: String):
	var sig := _game_sign(game, "w" if color == "White" else "b")
	if not _index.has(sig):
		return null
	var options := []
	for e in _index[sig]:
		var f: Vector2 = e["from"]
		# Re-validate against the real rules. The signature already guarantees the layout
		# matches, but a power-up could have made the move illegal (a Grounded piece cannot
		# move, a Shielded one cannot capture), so never trust the book blindly.
		if not game.board_state.has(f):
			continue
		if game.board_state[f]["color"] != color:
			continue
		if e["to"] in game.get_safe_moves(f):
			options.append(e)
	if options.is_empty():
		return null
	return options[rng.randi() % options.size()]

# --- internals ---

func _start_board() -> Dictionary:
	var b := {}
	for x in range(8):
		b[Vector2(x, 0)] = String(_BACK_RANK[x]).to_lower()
		b[Vector2(x, 1)] = "p"
		b[Vector2(x, 6)] = "P"
		b[Vector2(x, 7)] = String(_BACK_RANK[x])
	return b

# Uppercase = White, lowercase = Black. Order is fixed by square index, so the same
# layout always produces the same string.
func _sign(board: Dictionary, side: String) -> String:
	var keys := board.keys()
	keys.sort_custom(func(a, b): return (a.y * 8 + a.x) < (b.y * 8 + b.x))
	var parts := PackedStringArray()
	for k in keys:
		parts.append(str(int(k.x)) + str(int(k.y)) + String(board[k]))
	return side + "/" + "".join(parts)

func _game_sign(game, side: String) -> String:
	var b := {}
	for pos in game.board_state.keys():
		var pc: Dictionary = game.board_state[pos]
		var letter: String = String(_TYPE_CODE.get(pc["type"], "?"))
		# A Super Pawn has different geometry from a Pawn, so it is signed as "S" — a code
		# no book line can produce. That drops the bot out of book, which is correct.
		if pc.get("is_super_pawn", false):
			letter = "S"
		if pc["color"] == "Black":
			letter = letter.to_lower()
		b[pos] = letter
	return _sign(b, side)

func _apply_move(board: Dictionary, from_pos: Vector2, to_pos: Vector2) -> void:
	if not board.has(from_pos):
		return
	var code: String = board[from_pos]
	board.erase(from_pos)
	board[to_pos] = code
	# Castling is stored as the king move alone; move the matching rook to keep the
	# replayed layout honest (no book line contains en passant or promotion — the
	# generator asserts this — so those cases are deliberately not handled here).
	if code.to_upper() == "K" and absf(to_pos.x - from_pos.x) == 2.0:
		var rook_from := Vector2(7.0 if to_pos.x > from_pos.x else 0.0, from_pos.y)
		var rook_to := Vector2((from_pos.x + to_pos.x) / 2.0, from_pos.y)
		if board.has(rook_from):
			var rc: String = board[rook_from]
			board.erase(rook_from)
			board[rook_to] = rc
