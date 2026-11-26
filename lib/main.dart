// Black Moldow launcher — dart:ui pur. Layout dupa activity_main.xml,
// cu drawable-urile reale din proiectul Android. Inlocuieste App.framework/App.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

const _channelHost = 'ro.alynsampmobile.launcher/bridge';
const _ip = '51.75.44.14';
const _port = 8889;
const _serverName = 'BLACK MOLDOW';
String _nick = 'Nume_Prenume';
String _password = '';

const _cGold = Color(0xFFFFC62E);
const _cBg = Color(0xFF0B0B10);
const _cSurface = Color(0xFF1A1A22);
const _cWhite = Color(0xFFFFFFFF);
const _cMuted = Color(0xAFFFFFFF);

class _W {
  final BytesBuilder _b = BytesBuilder(copy: false);
  void u8(int v) => _b.add([v & 0xFF]);
  void u32(int v) => _b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u64(int v) {
    for (int i = 0; i < 8; i++) _b.add([(v >> (8 * i)) & 0xFF]);
  }

  void size(int n) {
    if (n < 254) {
      u8(n);
    } else if (n <= 0xFFFF) {
      u8(254);
      _b.add([n & 0xFF, (n >> 8) & 0xFF]);
    } else {
      u8(255);
      u32(n);
    }
  }

  void string(String s) {
    final b = utf8.encode(s);
    size(b.length);
    _b.add(b);
  }

  void value(Object? v) {
    if (v == null) { u8(0xFF); }
    else if (v is bool) { u8(v ? 1 : 2); }
    else if (v is int) {
      if (v >= -0x80000000 && v <= 0x7FFFFFFF) { u8(3); u32(v); }
      else { u8(4); u64(v); }
    } else if (v is String) { u8(7); string(v); }
    else if (v is Uint8List) { u8(8); size(v.length); _b.add(v); }
    else if (v is Map) {
      u8(13); size(v.length);
      v.forEach((k, val) { value(k.toString()); value(val); });
    } else if (v is List) {
      u8(12); size(v.length);
      for (final e in v) { value(e); }
    } else { value(v.toString()); }
  }

  ByteData done() => ByteData.sublistView(Uint8List.fromList(_b.takeBytes()));
}

ByteData _call(String method, Map<String, Object?> args) =>
    (_W()..value(method)..value(args)).done();

Future<ByteData?> _send(String channel, ByteData data) {
  final c = Completer<ByteData?>();
  window.sendPlatformMessage(channel, data, (r) {
    if (!c.isCompleted) c.complete(r);
  });
  return c.future;
}

Future<ByteData> loadAsset(String key) async {
  final r = await _send('flutter/assets', (_W()..value(key)).done());
  if (r == null) throw 'asset lipsa: $key';
  return r;
}

Future<Image?> loadImage(String key) async {
  try {
    final b = await loadAsset(key);
    final codec = await instantiateImageCodec(Uint8List.sublistView(b));
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  }
}

// ---- stare ----
Image? _bg;
final Map<String, Image?> _icons = {};
double _w = 0, _h = 0, _dpr = 1, _s = 1;
bool _showProfile = false, _joining = false;
bool _editNick = false, _kbShift = false;
int _kbPage = 0; // 0 = litere, 1 = cifre
String _status = '';
String _nickDraft = '';
Rect _rPlay = Rect.zero, _rProfile = Rect.zero, _rSettings = Rect.zero, _rBack = Rect.zero;
Rect _rNickEdit = Rect.zero, _rNickBtn = Rect.zero, _rNickOK = Rect.zero, _rNickCancel = Rect.zero, _rKbToggle = Rect.zero;
final List<Rect> _keyRects = <Rect>[];
final List<String> _keyLabels = <String>[];

double dp(double v) => v * _s;

// ---- citirea nickname-ului din client_settings.plist (acelasi ca vechiul launcher) ----
int _intAt(List<int> b, int off, int size) {
  int v = 0;
  for (int i = 0; i < size; i++) v = (v << 8) | b[off + i];
  return v;
}

Object? _bplistObject(List<int> b, int idx, List<int> offsets, int refSize) {
  final p = offsets[idx];
  final marker = b[p];
  final kind = marker >> 4;
  var n = marker & 0x0F;
  int q = p + 1;
  if (n == 15) {
    final m = b[q] >> 4;
    if (m == 1) {
      n = _intAt(b, q + 1, 1 << (b[q] & 0x0F));
      q += 1 + (1 << (b[q] & 0x0F));
    }
  }
  if (kind == 5) {
    return utf8.decode(b.sublist(q, q + n), allowMalformed: true);
  }
  if (kind == 6) {
    final u = Uint8List.sublistView(Uint8List.fromList(b.sublist(q, q + n * 2)));
    final s = StringBuffer();
    for (int i = 0; i < u.length; i += 2) s.writeCharCode((u[i] << 8) | u[i + 1]);
    return s.toString();
  }
  if (kind == 1) {
    final size = 1 << n;
    return _intAt(b, q, size);
  }
  if (kind == 0) return null;
  if (kind == 8) {
    final r = <Object?>[];
    for (int i = 0; i < n; i++) {
      r.add(_bplistObject(b, _intAt(b, q + i * refSize, refSize), offsets, refSize));
    }
    return r;
  }
  if (kind == 13) {
    final m = <String, Object?>{};
    for (int i = 0; i < n; i++) {
      final k = _bplistObject(b, _intAt(b, q + i * refSize, refSize), offsets, refSize);
      final v = _bplistObject(b, _intAt(b, q + (n + i) * refSize, refSize), offsets, refSize);
      m[k.toString()] = v;
    }
    return m;
  }
  return null;
}

Object? _parseBplist(List<int> b) {
  if (b.length < 40 || String.fromCharCodes(b.sublist(0, 8)) != 'bplist00') return null;
  final tr = b.length - 32;
  final offSize = b[tr + 6], refSize = b[tr + 7];
  final count = _intAt(b, tr + 8, 8);
  final top = _intAt(b, tr + 16, 8);
  final table = _intAt(b, tr + 24, 8);
  final offsets = <int>[];
  for (int i = 0; i < count; i++) offsets.add(_intAt(b, table + i * offSize, offSize));
  return _bplistObject(b, top, offsets, refSize);
}

Future<void> _readNick() async {
  final home = Platform.environment['HOME'];
  // Parola salvata (folosita la conectare si in dialogul de login).
  try {
    if (home != null) {
      final pf = File('$home/Documents/password.txt');
      if (await pf.exists()) _password = (await pf.readAsString()).trim();
    }
  } catch (_) {}
  // Preferim fisierul scris de launcher (editabil in aplicatie).
  final files = <String>[
    if (home != null) '$home/Documents/nickname.txt',
    '${Directory.current.path}/Documents/nickname.txt',
  ];
  for (final p in files) {
    try {
      final f = File(p);
      if (!await f.exists()) continue;
      final s = (await f.readAsString()).trim();
      if (s.isNotEmpty) {
        _nick = s;
        return;
      }
    } catch (_) {}
  }
  // Fallback: client_settings.plist (vechiul launcher).
  try {
    if (home == null) return;
    final f = File('$home/Library/Preferences/client_settings.plist');
    if (!await f.exists()) return;
    final obj = _parseBplist(await f.readAsBytes());
    if (obj is Map && obj['nick_name'] is String && (obj['nick_name'] as String).isNotEmpty) {
      _nick = obj['nick_name'] as String;
    }
  } catch (_) {}
}

Future<void> _saveNick(String s) async {
  try {
    final root = await _installRoot();
    await File('$root/nickname.txt').writeAsString(s);
  } catch (_) {}
}

Future<void> _load() async {
  await _readNick();
  _bg = await loadImage('assets/bg/home_calm.webp');
  for (final n in [
    'lobby_ic_settings', 'lobby_ic_profile', 'lobby_ic_swap', 'lobby_ic_crown',
    'lobby_ic_plus', 'lobby_ic_telegram', 'lobby_ic_play', 'lobby_ic_back',
    'cross_slot_plus',
  ]) {
    _icons[n] = await loadImage('assets/android/$n.png');
  }
  window.scheduleFrame();
}

void _txt(Canvas c, String s, double x, double y, double sp, Color color,
    {bool bold = true, TextAlign align = TextAlign.left, double? width}) {
  final pb = ParagraphBuilder(ParagraphStyle(textAlign: align))
    ..pushStyle(TextStyle(
      fontFamily: bold ? 'HalvarBd' : 'HalvarMd',
      fontSize: sp, color: color, height: 1))
    ..addText(s)
    ..pop();
  final p = pb.build()..layout(ParagraphConstraints(width: width ?? 2000));
  c.drawParagraph(p, Offset(x, y));
}

void _round(Canvas c, Rect r, double radius, Color color, {Color? stroke, double sw = 1}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
  c.drawRRect(rr, Paint()..color = color);
  if (stroke != null) {
    c.drawRRect(rr, Paint()..color = stroke..style = PaintingStyle.stroke..strokeWidth = sw);
  }
}

void _grad(Canvas c, Rect r, Color a, Color b, {bool vertical = false}) {
  for (int i = 0; i < 32; i++) {
    final t = i / 31;
    final col = Color.fromARGB(
      (((a.alpha / 255) * (1 - t) + (b.alpha / 255) * t) * 255).round(),
      (a.red * (1 - t) + b.red * t).round(),
      (a.green * (1 - t) + b.green * t).round(),
      (a.blue * (1 - t) + b.blue * t).round());
    if (vertical) {
      c.drawRect(Rect.fromLTWH(r.left, r.top + r.height * t, r.width, r.height / 31 + 1), Paint()..color = col);
    } else {
      c.drawRect(Rect.fromLTWH(r.left + r.width * t, r.top, r.width / 31 + 1, r.height), Paint()..color = col);
    }
  }
}

void _img(Canvas c, String name, Rect r, {Color? tint}) {
  final im = _icons[name];
  if (im == null) return;
  c.drawImageRect(im, Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()), r,
      Paint()..colorFilter = tint == null ? null : ColorFilter.mode(tint, BlendMode.srcIn));
}

void _background(Canvas c) {
  final rect = Offset.zero & Size(_w, _h);
  if (_bg != null) {
    final sc = math.max(_w / _bg!.width, _h / _bg!.height);
    final dw = _bg!.width * sc, dh = _bg!.height * sc;
    c.drawImageRect(_bg!, Rect.fromLTWH(0, 0, _bg!.width.toDouble(), _bg!.height.toDouble()),
        Rect.fromLTWH((_w - dw) / 2, (_h - dh) / 2, dw, dh), Paint());
  } else {
    c.drawRect(rect, Paint()..color = _cBg);
  }
  // background_menu.xml: #80000000 -> #a0f24c12, 45deg
  c.drawRect(rect, Paint()..color = const Color(0x66000000));
  _grad(c, rect, const Color(0x00000000), const Color(0x4AF24C12));
  _grad(c, Rect.fromLTWH(0, _h * 0.55, _w, _h * 0.45),
      const Color(0x00000000), const Color(0xB30B0B10), vertical: true);
}

void _iconBtn(Canvas c, Rect r, String icon,
    {Color bg = const Color(0xD20D1115), Color fg = _cWhite, bool yellow = false}) {
  _round(c, r, r.width / 2,
      yellow ? const Color(0xFFFFC933) : bg,
      stroke: yellow ? const Color(0xFFFFE8A6) : const Color(0x30FFFFFF));
  final pad = r.width * 0.28;
  _img(c, icon, Rect.fromLTWH(r.left + pad, r.top + pad, r.width - pad * 2, r.height - pad * 2), tint: fg);
}

void _lobbyDp(Canvas c) {
  final m = dp(18);

  // mainPlayerBlock: 206x72, marginStart 18, marginTop 20
  final px = m, py = dp(20);
  _txt(c, 'NIVEL 0', px, py, dp(17), _cWhite);
  _txt(c, _nick, px, py + dp(26), dp(21), _cWhite);
  final bs = dp(30);
  _rSettings = Rect.fromLTWH(px + dp(206) - bs, py, bs, bs);
  _rProfile = Rect.fromLTWH(_rSettings.left, py + dp(40), bs, bs);
  _iconBtn(c, _rSettings, 'lobby_ic_settings');
  _iconBtn(c, _rProfile, 'lobby_ic_profile');

  // topBalancePanel: marginTop 14, marginEnd 18, height 44
  final by = dp(14), bh = dp(38);
  var bx = _w - m;
  final plus = Rect.fromLTWH(bx - bh, by, bh, bh);
  _iconBtn(c, plus, 'lobby_ic_plus', yellow: true);
  bx -= bh + dp(6);
  _txt(c, '0', bx - dp(18), by + dp(7), dp(14), _cWhite, align: TextAlign.right, width: dp(18));
  bx -= dp(20);
  final crown = Rect.fromLTWH(bx - bh, by, bh, bh);
  _iconBtn(c, crown, 'lobby_ic_crown', yellow: true);
  bx -= bh + dp(8);
  final swap = Rect.fromLTWH(bx - bh, by, bh, bh);
  _iconBtn(c, swap, 'lobby_ic_swap');
  bx -= bh + dp(8);
  _txt(c, 'LEI 0', bx - dp(142), by + dp(5), dp(15), _cWhite, align: TextAlign.right, width: dp(142));

  // socialPanel: 390x166, marginStart 18, marginBottom 18
  final sy = _h - m - dp(166);
  _txt(c, 'Conturile noastre\npe retelele sociale', m, sy, dp(20), _cWhite);
  _txt(c, 'Urmărește-ne pe rețelele sociale și\nfii la curent cu noutățile', m, sy + dp(60), dp(12), _cMuted, bold: false);
  final sd = dp(48);
  var sx = m;
  for (final e in [
    ['VK', null],
    ['TG', 'lobby_ic_telegram'],
    ['DC', null],
  ]) {
    final r = Rect.fromLTWH(sx, sy + dp(118), sd, sd);
    _round(c, r, sd / 2, const Color(0xD20D1115), stroke: const Color(0x30FFFFFF));
    if (e[1] != null) {
      _img(c, e[1]! as String, Rect.fromLTWH(r.left + sd * 0.22, r.top + sd * 0.22, sd * 0.56, sd * 0.56));
    } else {
      _txt(c, e[0] as String, r.left, r.top + sd * 0.30, dp(14), _cWhite, align: TextAlign.center, width: sd);
    }
    sx += sd + dp(12);
  }

  // characterSlotsPanel: 3 x 36, marginEnd 34, 6dp intre
  final sd2 = dp(36), sx2 = _w - dp(34) - sd2;
  var sy2 = _h - dp(96) - dp(46) - dp(12) - 3 * sd2 - 2 * dp(6);
  final slotColors = [const Color(0xFFE94B4B), const Color(0xFF4B7BE9), const Color(0xFF4BE97B)];
  for (int i = 0; i < 3; i++) {
    final r = Rect.fromLTWH(sx2, sy2, sd2, sd2);
    _round(c, r, dp(9), const Color(0x18FFFFFF), stroke: const Color(0x45FFFFFF));
    final plusR = Rect.fromLTWH(r.left + sd2 * 0.32, r.top + sd2 * 0.32, sd2 * 0.36, sd2 * 0.36);
    _img(c, 'cross_slot_plus', plusR);
    final nb = Rect.fromLTWH(r.right - dp(11), r.top - dp(3), dp(14), dp(14));
    _round(c, nb, nb.width / 2, slotColors[i], stroke: _cWhite);
    _txt(c, '${i + 1}', nb.left, nb.top + dp(1), dp(8), _cWhite, align: TextAlign.center, width: nb.width);
    sy2 += sd2 + dp(6);
  }

  // launcherMainCurrentServer: 154x46, marginEnd 24, marginBottom 96
  final cw = dp(154), ch = dp(46);
  final cx = _w - dp(24) - cw, cy = _h - dp(96) - ch;
  _round(c, Rect.fromLTWH(cx, cy, cw, ch), dp(18), const Color(0xED1A1A22), stroke: const Color(0x32FFFFFF));
  final num = Rect.fromLTWH(cx + dp(8), cy + dp(7), dp(32), dp(32));
  _round(c, num, dp(6), const Color(0xFF101015), stroke: const Color(0x70FFC62E));
  _txt(c, '#1', num.left, num.top + dp(6), dp(15), _cGold, align: TextAlign.center, width: num.width);
  final tx = num.right + dp(8);
  _txt(c, _serverName, tx, cy + dp(6), dp(11), _cWhite);
  _txt(c, 'ÎNCĂRCARE MICĂ', tx, cy + dp(22), dp(7), _cMuted, bold: false);
  final pr = Rect.fromLTWH(tx, cy + dp(32), cw - dp(48), dp(3));
  c.drawRect(pr, Paint()..color = const Color(0xFF383838));
  c.drawRect(Rect.fromLTWH(pr.left, pr.top, pr.width * 0.08, pr.height), Paint()..color = _cGold);

  // btn_play: 190x62, marginEnd 24, marginBottom 24
  final bw = dp(190), bh2 = dp(62);
  _rPlay = Rect.fromLTWH(_w - dp(24) - bw, _h - dp(24) - bh2, bw, bh2);
  _grad(c, _rPlay, const Color(0xFFFFB71B), const Color(0xFFFFDE72));
  final ic = Rect.fromLTWH(_rPlay.left + dp(12), _rPlay.top + dp(12), dp(38), dp(38));
  _round(c, ic, ic.width / 2, const Color(0x2EFFFFFF), stroke: const Color(0x4A000000));
  _img(c, 'lobby_ic_play', Rect.fromLTWH(ic.left + dp(9), ic.top + dp(9), dp(20), dp(20)), tint: const Color(0xFF17191D));
  _txt(c, 'JOACA', ic.right + dp(13), _rPlay.top + dp(15), dp(25), const Color(0xFF111318));

  // versiune, jos centru
  _txt(c, 'Se incarca versiunea...', 0, _h - dp(16), dp(9), const Color(0xE0E0E0),
      bold: false, align: TextAlign.center, width: _w);
}

void _lobbyPercent(Canvas c) {
  final u = math.min(_w, _h);
  final pad = u * 0.02;

  // player block, stanga-sus
  _txt(c, 'NIVEL 0', pad, u * 0.028, u * 0.040, _cWhite);
  _txt(c, _nick, pad, u * 0.072, u * 0.052, _cWhite);
  final bs = u * 0.075;
  _rSettings = Rect.fromLTWH(pad + u * 0.30, u * 0.028, bs, bs);
  _rProfile = Rect.fromLTWH(_rSettings.left, u * 0.028 + bs + pad * 0.4, bs, bs);
  _iconBtn(c, _rSettings, 'lobby_ic_settings');
  _iconBtn(c, _rProfile, 'lobby_ic_profile');

  // balanta, dreapta-sus
  var x = _w - pad;
  final bh = u * 0.09;
  _iconBtn(c, Rect.fromLTWH(x - bh, u * 0.028, bh, bh), 'lobby_ic_plus', yellow: true);
  x -= bh + pad * 0.4;
  _txt(c, '0', x - u * 0.05, u * 0.048, u * 0.034, _cWhite, align: TextAlign.right, width: u * 0.05);
  x -= u * 0.06;
  _iconBtn(c, Rect.fromLTWH(x - bh, u * 0.028, bh, bh), 'lobby_ic_crown', yellow: true);
  x -= bh + pad * 0.3;
  _iconBtn(c, Rect.fromLTWH(x - bh, u * 0.028, bh, bh), 'lobby_ic_swap');
  x -= bh + pad * 0.3;
  _txt(c, 'LEI 0', x - u * 0.24, u * 0.044, u * 0.036, _cWhite, align: TextAlign.right, width: u * 0.24);

  // social, jos-stanga
  final sy = _h - pad - u * 0.21;
  _txt(c, 'Conturile noastre', pad, sy, u * 0.042, _cWhite);
  _txt(c, 'pe retelele sociale', pad, sy + u * 0.048, u * 0.042, _cWhite);
  _txt(c, 'Urmărește-ne pe rețelele sociale și\nfii la curent cu noutățile',
      pad, sy + u * 0.10, u * 0.024, _cMuted, bold: false);
  final sd = u * 0.085;
  var sx = pad;
  for (final e in [['VK', ''], ['TG', 'lobby_ic_telegram'], ['DC', '']]) {
    final r = Rect.fromLTWH(sx, sy + u * 0.145, sd, sd);
    _round(c, r, sd / 2, const Color(0xD20D1115), stroke: const Color(0x30FFFFFF));
    if (e[1].isNotEmpty) {
      _img(c, e[1], Rect.fromLTWH(r.left + sd * 0.22, r.top + sd * 0.22, sd * 0.56, sd * 0.56));
    } else {
      _txt(c, e[0], r.left, r.top + sd * 0.28, sd * 0.34, _cWhite, align: TextAlign.center, width: sd);
    }
    sx += sd + pad * 0.5;
  }

  // sloturi, dreapta
  final sd2 = u * 0.080;
  final xx = _w - pad - sd2;
  var yy = u * 0.30;
  final cols = [const Color(0xFFE94B4B), const Color(0xFF4B7BE9), const Color(0xFF3BE282)];
  for (int i = 0; i < 3; i++) {
    final r = Rect.fromLTWH(xx, yy, sd2, sd2);
    _round(c, r, sd2 * 0.2, const Color(0x18FFFFFF), stroke: const Color(0x45FFFFFF));
    _img(c, 'cross_slot_plus', Rect.fromLTWH(r.left + sd2 * 0.32, r.top + sd2 * 0.32, sd2 * 0.36, sd2 * 0.36));
    final nb = Rect.fromLTWH(r.right - sd2 * 0.30, r.top - sd2 * 0.06, sd2 * 0.32, sd2 * 0.32);
    _round(c, nb, nb.width / 2, cols[i], stroke: _cWhite);
    _txt(c, '${i + 1}', nb.left, nb.top + sd2 * 0.01, sd2 * 0.20, _cWhite, align: TextAlign.center, width: nb.width);
    yy += sd2 + pad * 0.35;
  }

  // card server, dreapta-jos
  final cw = math.min(_w * 0.25, u * 0.40), ch = u * 0.11;
  final cx = _w - pad - cw, cy = _h - pad - u * 0.245 - ch;
  _round(c, Rect.fromLTWH(cx, cy, cw, ch), ch * 0.28, const Color(0xED1A1A22), stroke: const Color(0x32FFFFFF));
  final num = Rect.fromLTWH(cx + ch * 0.12, cy + ch * 0.12, ch * 0.62, ch * 0.62);
  _round(c, num, ch * 0.12, const Color(0xFF101015), stroke: const Color(0x70FFC62E));
  _txt(c, '#1', num.left, num.top + ch * 0.12, ch * 0.34, _cGold, align: TextAlign.center, width: num.width);
  final tx = num.right + ch * 0.18;
  _txt(c, _serverName, tx, cy + ch * 0.12, ch * 0.24, _cWhite);
  _txt(c, 'ÎNCĂRCARE MICĂ', tx, cy + ch * 0.48, ch * 0.16, _cMuted, bold: false);
  final pr = Rect.fromLTWH(tx, cy + ch * 0.78, cw - (tx - cx) - ch * 0.18, ch * 0.05);
  c.drawRect(pr, Paint()..color = const Color(0xFF383838));
  c.drawRect(Rect.fromLTWH(pr.left, pr.top, pr.width * 0.08, pr.height), Paint()..color = _cGold);

  // buton JOACA, dreapta-jos
  final bw = math.min(_w * 0.25, u * 0.40), bh2 = u * 0.135;
  _rPlay = Rect.fromLTWH(_w - pad - bw, _h - pad - bh2, bw, bh2);
  _grad(c, _rPlay, const Color(0xFFFFB71B), const Color(0xFFFFDE72));
  final ic = Rect.fromLTWH(_rPlay.left + bh2 * 0.10, _rPlay.top + bh2 * 0.14, bh2 * 0.68, bh2 * 0.68);
  _round(c, ic, ic.width / 2, const Color(0x2EFFFFFF), stroke: const Color(0x4A000000));
  _img(c, 'lobby_ic_play', Rect.fromLTWH(ic.left + ic.width * 0.28, ic.top + ic.height * 0.28,
      ic.width * 0.44, ic.height * 0.44), tint: const Color(0xFF17191D));
  _txt(c, 'JOACA', ic.right + bh2 * 0.16, _rPlay.top + bh2 * 0.24, bh2 * 0.40, const Color(0xFF111318));

  _txt(c, 'Black Moldow  •  v2.0', 0, _h - pad * 0.6, u * 0.022, const Color(0xE0E0E0),
      bold: false, align: TextAlign.center, width: _w);
}

void _profile(Canvas c) {
  c.drawRect(Offset.zero & Size(_w, _h), Paint()..color = const Color(0xF50B0B10));
  final m = dp(18);
  _rBack = Rect.fromLTWH(dp(11.5), dp(11.5), dp(36), dp(36));
  _round(c, _rBack, dp(18), const Color(0xD20D1115), stroke: const Color(0x30FFFFFF));
  _img(c, 'lobby_ic_back', Rect.fromLTWH(_rBack.left + dp(9), _rBack.top + dp(9), dp(18), dp(18)));
  _txt(c, 'CONTUL MEU', _rBack.right + dp(10), dp(18), dp(14), _cWhite);
  var y = dp(52);
  _rNickEdit = Rect.fromLTWH(m - dp(4), y - dp(4), dp(230), dp(28));
  _round(c, _rNickEdit, dp(6), const Color(0x22FFFFFF), stroke: const Color(0x55FFC62E));
  _txt(c, _nick, m, y, dp(15.5), _cWhite);
  _round(c, Rect.fromLTWH(_rNickEdit.right + dp(6), y, dp(26), dp(22)), dp(5), _cGold);
  _txt(c, '✎', _rNickEdit.right + dp(6), y + dp(1), dp(16), const Color(0xFF111318),
      align: TextAlign.center, width: dp(26));
  y += dp(30);
  _txt(c, 'NV. 0', m, y, dp(9), _cWhite, bold: false);
  _txt(c, '0/1', m + dp(250), y, dp(7.1), const Color(0xB8FFFFFF), bold: false);
  final pr = Rect.fromLTWH(m, y + dp(12), dp(290), dp(3.5));
  c.drawRect(pr, Paint()..color = const Color(0xFF383838));
  c.drawRect(Rect.fromLTWH(pr.left, pr.top, pr.width * 0.01, pr.height), Paint()..color = _cGold);
  y += dp(40);
  final labels = [
    ['Bani în bancă', 'LEI 0'], ['Telefon', 'Nu are'], ['Casă', 'Nu are'],
    ['Job', 'Nu are'], ['Familie', 'Nu are'], ['Business', 'Nu are'],
  ];
  final cw = dp(150), ch = dp(42);
  for (int i = 0; i < labels.length; i++) {
    final x = m + (i % 2) * (cw + dp(6)), yy = y + (i ~/ 2) * (ch + dp(6));
    _round(c, Rect.fromLTWH(x, yy, cw, ch), dp(8), _cSurface, stroke: const Color(0x33FFFFFF));
    _txt(c, labels[i][0], x + dp(9.5), yy + dp(13), dp(7.8), _cWhite);
    _txt(c, labels[i][1], x + cw - dp(70), yy + dp(13), dp(7.8), _cGold, bold: false);
  }
  final lo = Rect.fromLTWH(m, y + 3 * (ch + dp(6)), dp(290), dp(38));
  _round(c, lo, dp(8), const Color(0xFF3A1215), stroke: const Color(0x66FF6B6B));
  _txt(c, 'ȘTERGE PERSONAJUL', lo.left, lo.top + dp(12), dp(9), _cWhite, align: TextAlign.center, width: lo.width);
  // Buton explicit pentru schimbarea numelui.
  final nb = Rect.fromLTWH(m, lo.bottom + dp(8), dp(290), dp(34));
  _round(c, nb, dp(8), const Color(0xFF1A1A22), stroke: const Color(0x66FFC62E));
  _txt(c, 'SCHIMBĂ NUMELE', nb.left, nb.top + dp(9), dp(10), _cGold,
      align: TextAlign.center, width: nb.width);
  _rNickBtn = nb;
}

// ---- editor de nickname cu tastatura desenata (fara TextInputClient) ----
void _keyTap(String label) {
  if (label == '⌫') {
    if (_nickDraft.isNotEmpty) {
      _nickDraft = _nickDraft.substring(0, _nickDraft.length - 1);
    }
  } else if (label == '␣') {
    if (_nickDraft.length < 24) _nickDraft += ' ';
  } else if (label == '⇧') {
    _kbShift = !_kbShift;
  } else if (label == '123') {
    _kbPage = 1;
  } else if (label == 'ABC') {
    _kbPage = 0;
  } else if (_nickDraft.length < 24) {
    _nickDraft += _kbShift ? label.toUpperCase() : label.toLowerCase();
  }
  window.scheduleFrame();
}

void _drawNickEditor(Canvas c) {
  c.drawRect(Offset.zero & Size(_w, _h), Paint()..color = const Color(0xF50B0B10));
  _txt(c, 'SCHIMBĂ NUMELE', 0, dp(44), dp(18), _cGold,
      align: TextAlign.center, width: _w);

  final m = dp(16);
  final field = Rect.fromLTWH(m, dp(92), _w - m * 2, dp(50));
  _round(c, field, dp(9), _cSurface, stroke: const Color(0x88FFC62E));
  final shown = _nickDraft.isEmpty ? '' : _nickDraft;
  _txt(c, shown, field.left + dp(11), field.top + dp(10), dp(17), _cWhite, bold: false);
  final cursorX = field.left + dp(11) + dp(shown.length * 17 * 0.56);
  c.drawRect(Rect.fromLTWH(cursorX, field.top + dp(10), dp(2), dp(28)),
      Paint()..color = _cGold);

  _keyRects.clear();
  _keyLabels.clear();
  final List<List<String>> rows = _kbPage == 0
      ? [
          ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
          ['⇧', 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
          ['123', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '␣', '⌫'],
        ]
      : [
          ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
          ['-', '@', '_', '.', ',', '!', '?', ':', '#', '/'],
          ['ABC', '␣', '⌫'],
        ];
  final kw = dp(34), kh = dp(38), gap = dp(4);
  final y0 = dp(168);
  for (int r = 0; r < rows.length; r++) {
    final row = rows[r];
    final totalW = row.length * kw + (row.length - 1) * gap;
    final x0 = (_w - totalW) / 2;
    for (int i = 0; i < row.length; i++) {
      final label = row[i];
      final kr = Rect.fromLTWH(x0 + i * (kw + gap), y0 + r * (kh + gap), kw, kh);
      final hot = (label == '⇧' && _kbShift) || (label == 'ABC' && _kbPage == 1) ||
          (label == '123' && _kbPage == 0);
      _round(c, kr, dp(6), hot ? const Color(0x66FFC62E) : const Color(0x2EFFFFFF),
          stroke: const Color(0x22FFFFFF));
      _txt(c, label, kr.left, kr.top + dp(9), label.length > 1 ? dp(10) : dp(14),
          hot ? _cGold : _cWhite, align: TextAlign.center, width: kw);
      _keyRects.add(kr);
      _keyLabels.add(label);
    }
  }

  final by = y0 + 3 * (kh + gap) + dp(12);
  final bw = (_w - m * 2 - gap) / 2;
  _rNickCancel = Rect.fromLTWH(m, by, bw, dp(44));
  _rNickOK = Rect.fromLTWH(m + bw + gap, by, bw, dp(44));
  _round(c, _rNickCancel, dp(8), const Color(0x33FFFFFF), stroke: const Color(0x55FFFFFF));
  _txt(c, 'ANULARE', _rNickCancel.left, _rNickCancel.top + dp(14), dp(12), _cWhite,
      align: TextAlign.center, width: bw);
  _round(c, _rNickOK, dp(8), const Color(0xFFFFC933));
  _txt(c, 'OK', _rNickOK.left, _rNickOK.top + dp(12), dp(14), const Color(0xFF111318),
      align: TextAlign.center, width: bw);
}

void _paint(Canvas c) {
  // Desenam direct in pixeli fizici: asa umple ecranul pe orice iPhone,
  // indiferent de devicePixelRatio (nu depindem de scalarea canvas-ului).
  _dpr = window.devicePixelRatio;
  _w = window.physicalSize.width;
  _h = window.physicalSize.height;
  // _s converteste dp -> pixeli fizici (referinta 390x844 dp, ca activity_main.xml)
  _s = math.min(_w / 390.0, _h / 844.0);
  _background(c);
  if (_editNick) {
    _drawNickEditor(c);
    return;
  }
  if (_showProfile) {
    _profile(c);
    return;
  }
  _lobbyDp(c);
  if (_status.isNotEmpty) {
    _txt(c, _status, 0, _h * 0.52, dp(12), _cGold, align: TextAlign.center, width: _w);
  }
}

void _pointer(PointerDataPacket packet) {
  for (final d in packet.data) {
    if (d.change != PointerChange.down) continue;
    final p = Offset(d.physicalX, d.physicalY);
    if (_editNick) {
      if (_rNickOK.contains(p)) {
        final s = _nickDraft.trim();
        if (s.isNotEmpty) {
          _nick = s;
          _saveNick(s);
        }
        _editNick = false;
      } else if (_rNickCancel.contains(p)) {
        _editNick = false;
      } else {
        for (int i = 0; i < _keyRects.length; i++) {
          if (_keyRects[i].contains(p)) {
            _keyTap(_keyLabels[i]);
            break;
          }
        }
      }
      window.scheduleFrame();
      continue;
    }
    if (_showProfile) {
      if (_rBack.contains(p)) {
        _showProfile = false;
        window.scheduleFrame();
      } else if (_rNickEdit.contains(p) || _rNickBtn.contains(p)) {
        _nickDraft = _nick;
        _kbShift = false;
        _kbPage = 0;
        _editNick = true;
        window.scheduleFrame();
      }
    } else if (_rPlay.contains(p)) {
      _join();
    } else if (_rProfile.contains(p) || _rSettings.contains(p)) {
      _showProfile = true;
      window.scheduleFrame();
    }
  }
}

// ---- raspuns StandardMethodCodec: 0 (success) + 7 (string) + size + utf8 ----
String? _replyString(ByteData? r) {
  if (r == null || r.lengthInBytes < 3) return null;
  final b = Uint8List.sublistView(r);
  int i = 0;
  if (b[i++] != 0) return null; // nu e raspuns de succes
  if (b[i++] != 7) return null; // nu e string
  int n = b[i++];
  if (n == 254) {
    if (i + 2 > b.length) return null;
    n = b[i] | (b[i + 1] << 8);
    i += 2;
  } else if (n == 255) {
    if (i + 4 > b.length) return null;
    n = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
    i += 4;
  }
  if (i + n > b.length) return null;
  return utf8.decode(b.sublist(i, i + n));
}

// ---- eroarea din raspuns StandardMethodCodec (0x01 + cod + mesaj + detalii) ----
String? _replyError(ByteData? r) {
  if (r == null || r.lengthInBytes < 2) return null;
  final b = Uint8List.sublistView(r);
  if (b[0] != 1) return null;
  final s = StringBuffer();
  for (final x in b) {
    if (x >= 32 && x < 127) s.writeCharCode(x);
  }
  final t = s.toString().trim();
  return t.isEmpty ? 'eroare necunoscuta' : t;
}

// ---- bool din raspuns StandardMethodCodec: 0x00 success + 0x01 true / 0x02 false ----
bool? _replyBool(ByteData? r) {
  if (r == null || r.lengthInBytes < 2) return null;
  final b = Uint8List.sublistView(r);
  if (b[0] != 0) return null;
  if (b[1] == 1) return true;
  if (b[1] == 2) return false;
  return null;
}

Future<String> _installRoot() async {
  // Doar metode care EXISTA in bridge-ul nativ: installRoot / externalFilesDir.
  // (installRootURL nu exista -> bridge intoarce FlutterMethodNotImplemented,
  //  codecul standard nu poate encoda NSObject-ul si aplicatia crapa.)
  for (final m in ['installRoot', 'externalFilesDir']) {
    try {
      final r = await _send(_channelHost, _call(m, <String, Object?>{}));
      var s = _replyString(r);
      if (s != null && s.isNotEmpty) {
        if (s.startsWith('file://')) s = Uri.parse(s).toFilePath();
        if (!s.startsWith('/')) {
          final home = Platform.environment['HOME'];
          if (home != null && home.startsWith('/')) s = '$home/$s';
        }
        if (s.startsWith('/')) {
          Directory(s).createSync(recursive: true);
          return s;
        }
      }
    } catch (_) {}
  }
  // Fallback: containerul de date al aplicatiei.
  final home = Platform.environment['HOME'];
  final cwd = Directory.current.path;
  final candidates = <String>[
    if (home != null && home.startsWith('/')) '$home/Documents',
    '$cwd/Documents',
    cwd,
  ];
  for (final c in candidates) {
    if (File('$c/textures/game.bin').existsSync() || File('$c/SAMP/gta.dat').existsSync()) {
      return c;
    }
  }
  final fallback = candidates.first;
  Directory(fallback).createSync(recursive: true);
  return fallback;
}

const _ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15';

Future<List<Object?>> _manifest() async {
  // fara User-Agent, resa-mp.com intoarce 403
  final client = HttpClient()..userAgent = _ua;
  try {
    final req = await client.getUrl(Uri.parse('https://resa-mp.com/api/game-files'));
    req.headers.set('Accept', 'application/json');
    final resp = await req.close();
    if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode} lista de fișiere';
    final body = await utf8.decoder.bind(resp).join();
    final data = jsonDecode(body);
    return (data['files'] as List).cast<Object?>();
  } finally {
    client.close();
  }
}

Future<void> _downloadFiles(List<Object?> files, String root) async {
  final client = HttpClient()..userAgent = _ua;
  try {
    for (int i = 0; i < files.length; i++) {
      final f = files[i] as Map;
      final path = f['path'].toString();
      final want = int.tryParse(f['size'].toString());
      final out = File('$root/$path');
      if (want != null && await out.exists() && await out.length() == want) continue;
      await out.parent.create(recursive: true);
      final url = Uri.parse(f['url'].toString());
      final part = File('$root/$path.part');
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode} pentru $path';
      }
      final sink = part.openWrite();
      await resp.forEach((chunk) {
        sink.add(chunk);
      });
      await sink.close();
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
      _status = 'Descarc fișiere ${i + 1}/${files.length}';
      window.scheduleFrame();
    }
  } finally {
    client.close();
  }
}

Future<void> _join() async {
  if (_joining) return;
  _joining = true;
  _status = 'Verific fișierele jocului...';
  window.scheduleFrame();
  String root;
  try {
    root = await _installRoot();
    _status = 'Descarc lista de fișiere...';
    window.scheduleFrame();
    final files = await _manifest();
    var missing = 0;
    for (final e in files) {
      final f = e as Map;
      final file = File('$root/${f['path']}');
      final want = int.tryParse(f['size'].toString());
      if (!await file.exists() || (want != null && await file.length() != want)) {
        missing++;
      }
    }
    if (missing > 0) {
      await _downloadFiles(files, root);
    }
  } catch (e) {
    _status = 'Eroare: $e';
    _joining = false;
    window.scheduleFrame();
    return;
  }

  _status = 'Conectare la $_serverName...';
  window.scheduleFrame();
  try {
    final expiry = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    final reply = await _send(_channelHost, _call('startGame', <String, Object?>{
      // installRoot este obligatoriu: handler-ul il valideaza inainte de orice.
      'installRoot': root,
      'nickname': _nick,
      'host': _ip,
      'port': _port,
      'password': _password,
      'serverName': _serverName,
      'sessionToken': 'bm-local-${DateTime.now().millisecondsSinceEpoch}',
      'sessionExpiresAt': expiry,
      'hasRun': true,
      'uiState': 'lobby',
    }));
    final err = _replyError(reply);
    if (err != null) {
      _status = 'Jocul nu a pornit: $err';
    } else {
      final ok = _replyBool(reply);
      if (ok == true) {
        _status = '';
      } else if (ok == false) {
        _status = 'Jocul nu a pornit (bridge: false)';
      } else {
        _status = 'Jocul nu a pornit (răspuns necunoscut)';
      }
    }
  } catch (e) {
    _status = 'Eroare start: $e';
  }
  _joining = false;
  window.scheduleFrame();
}

// ===================== UI in-joc (entrypoint ingameMain) =====================
// Vechiul App continea acest entrypoint cu tot HUD-ul si controalele touch.
// Il reconstruim aici. Suprafata e transparenta (native seteaza
// setOpaque:NO / backgroundColor nil), deci lumea 3D ramane vizibila.

const _igChan = 'ro.alynsampmobile.launcher/ingame_host';
bool _igChatOpen = false, _igScoreOpen = false;
bool _igDialogOpen = false, _igDkShift = false;
int _igDkPage = 0, _igFrame = 0;
String _igInput = '';
final List<String> _igMessages = <String>[];
final List<Rect> _igKeyRects = <Rect>[];
final List<String> _igKeyLabels = <String>[];
Rect _igDlgOK = Rect.zero, _igDlgCancel = Rect.zero, _igDlgClose = Rect.zero;

typedef _MallocNative = ffi.Pointer<ffi.Void> Function(ffi.UintPtr);
typedef _MallocDart = ffi.Pointer<ffi.Void> Function(int);
typedef _ReadNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ReadDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _SubmitNative = ffi.Int32 Function(ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _SubmitDart = int Function(int, int, ffi.Pointer<ffi.Void>, int);
_ReadDart? _igReadMetrics;
_SubmitDart? _igSubmit;
ffi.Pointer<ffi.Void>? _igBuf;

void _igInitNative() {
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _igBuf = malloc(72);
    _igReadMetrics = lib.lookupFunction<_ReadNative, _ReadDart>('resa_ui_read_metrics');
    _igSubmit = lib.lookupFunction<_SubmitNative, _SubmitDart>('resa_ui_submit_command');
  } catch (_) {}
}

void _igSendInput(String s) {
  if (s.isEmpty) return;
  try {
    final bytes = utf8.encode(s);
    final p = mallocTyped(bytes.length + 1);
    for (int i = 0; i < bytes.length; i++) p[i] = bytes[i];
    p[bytes.length] = 0;
    _igSubmit?.call(0, 0x10000, p.cast<ffi.Void>(), bytes.length);
  } catch (_) {}
  try {
    window.sendPlatformMessage(
        _igChan, _call('message', <String, Object?>{'message': s}), (_) {});
  } catch (_) {}
  _igMessages.add('→ $s');
  if (_igMessages.length > 8) _igMessages.removeAt(0);
}

ffi.Pointer<ffi.Uint8> mallocTyped(int n) {
  final lib = ffi.DynamicLibrary.process();
  final m = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  return m(n).cast<ffi.Uint8>();
}

List<double> _igMetrics() {
  try {
    if (_igReadMetrics == null || _igBuf == null) return const <double>[];
    _igReadMetrics!(_igBuf!, 72);
    return _igBuf!.cast<ffi.Float>().asTypedList(18).toList();
  } catch (_) {
    return const <double>[];
  }
}

// Decodor StandardMethodCodec pentru mesajele native -> Dart.
class _R {
  final Uint8List b;
  int i = 0;
  _R(this.b);
  int u8() => i < b.length ? b[i++] : 0;
  int size() {
    final n = u8();
    if (n == 254) {
      if (i + 2 > b.length) return 0;
      final v = b[i] | (b[i + 1] << 8);
      i += 2;
      return v;
    }
    if (n == 255) {
      if (i + 4 > b.length) return 0;
      final v = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
      i += 4;
      return v;
    }
    return n;
  }

  Object? value() {
    final t = u8();
    if (t == 0) return null;
    if (t == 1) return true;
    if (t == 2) return false;
    if (t == 3 || t == 4) {
      final n = t == 3 ? 4 : 8;
      int v = 0;
      for (int k = 0; k < n; k++) v |= u8() << (8 * k);
      return v;
    }
    if (t == 7) {
      final n = size();
      if (i + n > b.length) return '';
      final s = utf8.decode(b.sublist(i, i + n), allowMalformed: true);
      i += n;
      return s;
    }
    if (t == 12) {
      final n = size();
      return List<Object?>.generate(n, (_) => value());
    }
    if (t == 13) {
      final n = size();
      final m = <String, Object?>{};
      for (int k = 0; k < n; k++) {
        final key = value();
        m[key.toString()] = value();
      }
      return m;
    }
    return null;
  }
}

void _igMsg(String name, ByteData? data, void Function(ByteData?)? reply) {
  if (data == null) return;
  try {
    final r = _R(Uint8List.sublistView(data));
    final method = r.value();
    if (method is! String) return;
    final args = r.value();
    if (method == 'resa_ui_remote_command' || method == 'message') {
      final s = args is Map ? args['text'] ?? args['message'] : null;
      if (s is String && s.isNotEmpty) {
        _igMessages.add(s);
        if (_igMessages.length > 8) _igMessages.removeAt(0);
        window.scheduleFrame();
      }
    }
  } catch (_) {}
  if (reply != null) reply(null);
}

void _igBtn(Canvas c, Rect r, String label, {Color fill = const Color(0x66000000)}) {
  _round(c, r, r.width / 2, fill, stroke: const Color(0x99FFFFFF), sw: dp(1.5));
  _txt(c, label, r.left, r.top + r.height * 0.28, dp(13), _cWhite,
      align: TextAlign.center, width: r.width);
}

void _igKey(String k) {
  if (k == '⌫') {
    if (_igInput.isNotEmpty) _igInput = _igInput.substring(0, _igInput.length - 1);
  } else if (k == '␣') {
    if (_igInput.length < 40) _igInput += ' ';
  } else if (k == '⇧') {
    _igDkShift = !_igDkShift;
  } else if (k == '123') {
    _igDkPage = 1;
  } else if (k == 'ABC') {
    _igDkPage = 0;
  } else if (_igInput.length < 40) {
    _igInput += _igDkShift ? k.toUpperCase() : k.toLowerCase();
  }
  window.scheduleFrame();
}

void _igDrawDialog(Canvas c) {
  // Panou dialog (stil SA-MP): titlu, text, camp de introducere, OK / Cancel.
  final w = math.min(_w * 0.6, dp(520));
  final h = dp(300);
  final box = Rect.fromLTWH((_w - w) / 2, (_h - h) / 2 - dp(20), w, h);
  _round(c, box, dp(10), const Color(0xF2101218), stroke: const Color(0xFFE8A93B), sw: dp(2));
  _txt(c, 'BLACK MOLDOW', box.left, box.top + dp(14), dp(16), _cGold,
      align: TextAlign.center, width: box.width);
  _txt(c, 'Introdu parola contului:', box.left, box.top + dp(46), dp(12), _cWhite,
      align: TextAlign.center, width: box.width);

  final field = Rect.fromLTWH(box.left + dp(24), box.top + dp(72), box.width - dp(48), dp(34));
  _round(c, field, dp(6), const Color(0xFF050508), stroke: const Color(0x88FFC62E));
  final masked = '*' * _igInput.length;
  _txt(c, masked, field.left + dp(9), field.top + dp(7), dp(14), _cWhite, bold: false);

  _igDlgOK = Rect.fromLTWH(box.left + box.width / 2 + dp(6), box.top + dp(112), dp(90), dp(30));
  _igDlgCancel = Rect.fromLTWH(box.left + box.width / 2 - dp(96), box.top + dp(112), dp(90), dp(30));
  _round(c, _igDlgOK, dp(6), const Color(0xFFFFC933));
  _txt(c, 'OK', _igDlgOK.left, _igDlgOK.top + dp(7), dp(12), const Color(0xFF111318),
      align: TextAlign.center, width: _igDlgOK.width);
  _round(c, _igDlgCancel, dp(6), const Color(0x33FFFFFF), stroke: const Color(0x66FFFFFF));
  _txt(c, 'ANULARE', _igDlgCancel.left, _igDlgCancel.top + dp(7), dp(11), _cWhite,
      align: TextAlign.center, width: _igDlgCancel.width);

  // TastaturaQWERTY in partea de jos a dialogului.
  _igKeyRects.clear();
  _igKeyLabels.clear();
  final rows = _igDkPage == 0
      ? [
          ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
          ['⇧', 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
          ['123', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '␣', '⌫'],
        ]
      : [
          ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
          ['-', '@', '_', '.', ',', '!', '?', ':', '#', '/'],
          ['ABC', '␣', '⌫'],
        ];
  final kw = dp(32), kh = dp(32), gap = dp(3);
  final y0 = box.top + dp(152);
  for (int r = 0; r < rows.length; r++) {
    final row = rows[r];
    final tw = row.length * kw + (row.length - 1) * gap;
    final x0 = box.left + (box.width - tw) / 2;
    for (int i = 0; i < row.length; i++) {
      final kr = Rect.fromLTWH(x0 + i * (kw + gap), y0 + r * (kh + gap), kw, kh);
      _round(c, kr, dp(4), const Color(0x3AFFFFFF), stroke: const Color(0x22FFFFFF));
      _txt(c, row[i], kr.left, kr.top + dp(8), dp(11), _cWhite, align: TextAlign.center, width: kw);
      _igKeyRects.add(kr);
      _igKeyLabels.add(row[i]);
    }
  }
}

void _drawInGame(Canvas c) {
  _w = window.physicalSize.width;
  _h = window.physicalSize.height;
  // Referinta landscape 844x390 (jocul ruleaza landscape).
  _s = math.min(_w / 844.0, _h / 390.0);

  final vals = _igMetrics();
  double health = vals.isNotEmpty ? vals[0] : 100;
  double armour = vals.length > 1 ? vals[1] : 0;
  if (health.isNaN || health < 0 || health > 200) health = 100;
  if (armour.isNaN || armour < 0 || armour > 200) armour = 0;

  // --- HUD stanga sus: sanatate / armura / bani ---
  final barW = dp(150), barH = dp(9);
  final bx = dp(14), by = dp(14);
  _txt(c, 'HP', bx, by - dp(1), dp(9), const Color(0xFFE0E0E0), bold: false);
  _round(c, Rect.fromLTWH(bx + dp(24), by, barW, barH), dp(4), const Color(0xAA101014));
  _round(c, Rect.fromLTWH(bx + dp(24), by, barW * (health / 100).clamp(0.0, 1.0), barH),
      dp(4), const Color(0xFF35C75A));
  _txt(c, 'AR', bx, by + dp(14), dp(9), const Color(0xFFE0E0E0), bold: false);
  _round(c, Rect.fromLTWH(bx + dp(24), by + dp(15), barW, barH), dp(4), const Color(0xAA101014));
  _round(c, Rect.fromLTWH(bx + dp(24), by + dp(15), barW * (armour / 100).clamp(0.0, 1.0), barH),
      dp(4), const Color(0xFF4A8FE7));

  // --- Radar dreapta sus ---
  final rr = dp(46);
  final radar = Rect.fromLTWH(_w - dp(14) - rr * 2, dp(10), rr * 2, rr * 2);
  c.drawCircle(radar.center, rr, Paint()..color = const Color(0x660A0A10));
  c.drawCircle(radar.center, rr, Paint()
    ..color = const Color(0xAAFFFFFF)..style = PaintingStyle.stroke..strokeWidth = dp(1.5));
  c.drawLine(Offset(radar.center.dx - rr, radar.center.dy),
      Offset(radar.center.dx + rr, radar.center.dy),
      Paint()..color = const Color(0x44FFFFFF)..strokeWidth = dp(1));
  for (int k = 0; k < 5; k++) {
    final ang = (k * 1.257 + (_igFrame / 240)) % (math.pi * 2);
    c.drawCircle(
        radar.center + Offset(math.cos(ang) * rr * 0.62, math.sin(ang) * rr * 0.62),
        dp(2.5), Paint()..color = k == 0 ? _cGold : const Color(0xFFE05353));
  }

  // --- Stele wanted ---
  for (int k = 0; k < 6; k++) {
    final x = _w / 2 - dp(45) + k * dp(16);
    _txt(c, '★', x, dp(12), dp(12),
        k < 0 ? _cGold : const Color(0x55FFFFFF), align: TextAlign.center, width: dp(14));
  }

  // --- Controale touch: stick stanga jos ---
  final stickC = Offset(dp(80), _h - dp(78));
  c.drawCircle(stickC, dp(46), Paint()..color = const Color(0x33000000));
  c.drawCircle(stickC, dp(46), Paint()
    ..color = const Color(0x77FFFFFF)..style = PaintingStyle.stroke..strokeWidth = dp(2));
  c.drawCircle(stickC + const Offset(0, 0), dp(19), Paint()..color = const Color(0x88FFFFFF));

  // --- Butoane actiune dreapta jos ---
  final br = _h - dp(40);
  _igBtn(c, Rect.fromLTWH(_w - dp(92), br - dp(92), dp(64), dp(64)), 'FIRE',
      fill: const Color(0x66B82626));
  _igBtn(c, Rect.fromLTWH(_w - dp(168), br - dp(70), dp(52), dp(52)), 'AIM');
  _igBtn(c, Rect.fromLTWH(_w - dp(160), br - dp(140), dp(46), dp(46)), 'RUN');
  _igBtn(c, Rect.fromLTWH(_w - dp(232), br - dp(118), dp(46), dp(46)), 'JUMP');
  _igBtn(c, Rect.fromLTWH(_w - dp(38), br - dp(160), dp(34), dp(34)), '↑');

  // --- Butoane chat / score / harta ---
  _igBtn(c, Rect.fromLTWH(dp(160), br - dp(34), dp(44), dp(34)), 'CHAT');
  _igBtn(c, Rect.fromLTWH(dp(210), br - dp(34), dp(44), dp(34)), 'TAB');
  _igBtn(c, Rect.fromLTWH(dp(260), br - dp(34), dp(44), dp(34)), 'MAP');
  _igBtn(c, Rect.fromLTWH(dp(310), br - dp(34), dp(52), dp(34)), 'LOGIN',
      fill: const Color(0x66FFC933));

  // --- Panou chat ---
  if (_igChatOpen) {
    final cr = Rect.fromLTWH(dp(14), _h * 0.42, dp(330), dp(150));
    _round(c, cr, dp(8), const Color(0xC8000B10), stroke: const Color(0x66FFC62E));
    var y = cr.top + dp(8);
    for (final m in _igMessages) {
      _txt(c, m, cr.left + dp(10), y, dp(10), _cWhite, bold: false, width: cr.width - dp(20));
      y += dp(15);
    }
  }

  // --- Scoreboard ---
  if (_igScoreOpen) {
    final sr = Rect.fromLTWH(_w * 0.25, _h * 0.18, _w * 0.5, _h * 0.55);
    _round(c, sr, dp(10), const Color(0xE0000B10), stroke: const Color(0x88FFC62E));
    _txt(c, 'BLACK MOLDOW', sr.left, sr.top + dp(12), dp(16), _cGold,
        align: TextAlign.center, width: sr.width);
    _txt(c, 'Jucători conectați', sr.left, sr.top + dp(38), dp(11), _cWhite,
        align: TextAlign.center, width: sr.width);
  }

  // --- Dialog de login cu tastatura ---
  if (_igDialogOpen) _igDrawDialog(c);
}

void _igPointer(PointerDataPacket packet) {
  for (final d in packet.data) {
    if (d.change != PointerChange.down) continue;
    final p = Offset(d.physicalX, d.physicalY);
    if (_igDialogOpen) {
      if (_igDlgOK.contains(p)) {
        final s = _igInput.trim();
        if (s.isNotEmpty) _igSendInput(s);
        _igDialogOpen = false;
        _igInput = '';
      } else if (_igDlgCancel.contains(p)) {
        _igDialogOpen = false;
        _igInput = '';
      } else {
        for (int i = 0; i < _igKeyRects.length; i++) {
          if (_igKeyRects[i].contains(p)) {
            _igKey(_igKeyLabels[i]);
            break;
          }
        }
      }
      window.scheduleFrame();
      continue;
    }
    final br = _h - dp(40);
    if ((Offset(dp(336), br - dp(17)) - p).distance < dp(45)) {
      _igDialogOpen = true;
      _igInput = _password;
      _igDkShift = false;
      _igDkPage = 0;
    } else if ((Offset(dp(182), br - dp(17)) - p).distance < dp(40)) {
      _igChatOpen = !_igChatOpen;
    } else if ((Offset(dp(232), br - dp(17)) - p).distance < dp(40)) {
      _igScoreOpen = !_igScoreOpen;
    }
    window.scheduleFrame();
  }
}

@pragma('vm:entry-point')
void ingameMain() {
  _igInitNative();
  window.onPlatformMessage = _igMsg;
  window.onPointerDataPacket = _igPointer;
  window.onDrawFrame = () {
    _igFrame++;
    final rec = PictureRecorder();
    final c = Canvas(rec);
    // Fundal transparent: lumea 3D a jocului ramane vizibila.
    _drawInGame(c);
    window.render((SceneBuilder()..addPicture(Offset.zero, rec.endRecording())).build());
    window.scheduleFrame();
  };
  window.scheduleFrame();
}

void main() {
  _dpr = window.devicePixelRatio;
  window.onPointerDataPacket = _pointer;
  window.onDrawFrame = () {
    _dpr = window.devicePixelRatio;
    final rec = PictureRecorder();
    final canvas = Canvas(rec);
    _paint(canvas);
    window.render((SceneBuilder()..addPicture(Offset.zero, rec.endRecording())).build());
    if (_bg == null) window.scheduleFrame();
  };
  window.scheduleFrame();
  _load();
}
