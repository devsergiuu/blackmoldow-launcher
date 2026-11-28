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
Rect _rLobbyNick = Rect.zero;
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

// Calea reala a plist-ului launcherului iOS: <container>/Library/Preferences/client_settings.plist.
// HOME nu e setat in isolated-ul Dart, deci derivam containerul din Documents (installRoot).
Future<String> _settingsPlistPath() async {
  try {
    final docs = await _installRoot();
    final container = Directory(docs).parent.path;
    return '$container/Library/Preferences/client_settings.plist';
  } catch (_) {
    final home = Platform.environment['HOME'];
    return home != null ? '$home/Library/Preferences/client_settings.plist' : '';
  }
}

Future<void> _readNick() async {
  final p = await _settingsPlistPath();
  if (p.isEmpty) return;
  try {
    final f = File(p);
    if (!await f.exists()) return;
    final obj = _parseBplist(await f.readAsBytes());
    if (obj is! Map) return;
    final n = obj['nick_name'];
    if (n is String && n.isNotEmpty) _nick = n;
    final pw = obj['server_password'];
    if (pw is String && pw.isNotEmpty) _password = pw;
  } catch (_) {}
}

// Scrie in acelasi plist folosit de launcherul original (XML plist, compatibil
// cu PropertyListSerialization). Pastreaza toate cheile existente.
Future<void> _saveNick(String s) async {
  try {
    final p = await _settingsPlistPath();
    if (p.isEmpty) return;
    final f = File(p);
    Map<String, Object?> data = <String, Object?>{};
    if (await f.exists()) {
      final obj = _parseBplist(await f.readAsBytes());
      if (obj is Map) data = Map<String, Object?>.from(obj);
    }
    data['nick_name'] = s;
    final hist = <String>[s];
    final old = data['nickname_history'];
    if (old is String) {
      for (final m in RegExp(r'"([^"]+)"').allMatches(old)) {
        final v = m.group(1);
        if (v != null && v.isNotEmpty && !hist.contains(v)) hist.add(v);
      }
    }
    data['nickname_history'] = jsonEncode(hist);
    final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n');
    data.forEach((k, v) {
      sb.write('<key>$k</key>');
      if (v is String) {
        final esc = v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
        sb.write('<string>$esc</string>\n');
      } else if (v is bool) {
        sb.write(v ? '<true/>\n' : '<false/>\n');
      } else if (v is int) {
        sb.write('<integer>$v</integer>\n');
      } else if (v is num) {
        sb.write('<real>$v</real>\n');
      } else {
        sb.write('<string>${v.toString()}</string>\n');
      }
    });
    sb.write('</dict></plist>\n');
    await f.writeAsString(sb.toString());
  } catch (_) {}
}

Future<void> _savePassword(String s) async {
  try {
    final p = await _settingsPlistPath();
    if (p.isEmpty) return;
    final f = File(p);
    Map<String, Object?> data = <String, Object?>{};
    if (await f.exists()) {
      final obj = _parseBplist(await f.readAsBytes());
      if (obj is Map) data = Map<String, Object?>.from(obj);
    }
    data['server_password'] = s;
    final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n');
    data.forEach((k, v) {
      sb.write('<key>$k</key>');
      if (v is String) {
        final esc = v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
        sb.write('<string>$esc</string>\n');
      } else if (v is bool) {
        sb.write(v ? '<true/>\n' : '<false/>\n');
      } else if (v is int) {
        sb.write('<integer>$v</integer>\n');
      } else if (v is num) {
        sb.write('<real>$v</real>\n');
      } else {
        sb.write('<string>${v.toString()}</string>\n');
      }
    });
    sb.write('</dict></plist>\n');
    await f.writeAsString(sb.toString());
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
  _rLobbyNick = Rect.fromLTWH(px - dp(4), py + dp(22), dp(200), dp(32));
  _round(c, _rLobbyNick, dp(6), const Color(0x22FFFFFF), stroke: const Color(0x66FFC62E));
  _txt(c, _nick, px, py + dp(26), dp(21), _cWhite);
  _txt(c, '✎', _rLobbyNick.right - dp(22), py + dp(28), dp(15), _cGold);
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
    } else if (_rLobbyNick.contains(p)) {
      // Tap pe nume -> editor; la salvare se scrie nickname.txt si se foloseste la startGame.
      _nickDraft = _nick;
      _kbShift = false;
      _kbPage = 0;
      _editNick = true;
      window.scheduleFrame();
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
Image? _igBg, _igSkin;
// Dialoguri SA-MP primite de la motor in timpul jocului.
int _igDlgId = 1;
String _igDlgTitle = 'BLACK MOLDOW', _igDlgText = '';
List<String> _igDlgButtons = <String>['Intră', 'Anulare'];
bool _igDlgHasInput = true;
Rect _igDlgLoginBtn = Rect.zero;

typedef _MallocNative = ffi.Pointer<ffi.Void> Function(ffi.UintPtr);
typedef _MallocDart = ffi.Pointer<ffi.Void> Function(int);
typedef _ReadNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ReadDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _SubmitNative = ffi.Int32 Function(ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _SubmitDart = int Function(int, int, ffi.Pointer<ffi.Void>, int);
typedef _ConnectNative = ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.Pointer<ffi.Void>);
typedef _ConnectDart = ffi.Pointer<ffi.Void> Function(int, ffi.Pointer<ffi.Void>);
typedef _AcquireNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _AcquireDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _IsAttachedNative = ffi.Int32 Function();
typedef _IsAttachedDart = int Function();
_ReadDart? _igReadMetrics;
_SubmitDart? _igSubmit;
_ConnectDart? _igConnect;
_AcquireDart? _igAcquire;
_IsAttachedDart? _igIsAttached;
ffi.Pointer<ffi.Void>? _igBuf, _igHandle;
int _igAttached = -1;
int _igBase = 0;
// Referente globale: altfel GC elibereaza callback-ul si vtable devine invalida.
ffi.NativeCallable<ffi.Void Function()>? _igCb;
ffi.Pointer<ffi.Void>? _igVtKept, _igCtxKept;

void _igLoadAssets() {
  loadImage('assets/auth/auth_bg.png').then((v) {
    _igBg = v;
    window.scheduleFrame();
  });
  loadImage('assets/auth/auth_skin.png').then((v) {
    _igSkin = v;
    window.scheduleFrame();
  });
}

void _igInitNative() {
  try {
    final lib = ffi.DynamicLibrary.process();
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _igBuf = malloc(72);
    _igReadMetrics = lib.lookupFunction<_ReadNative, _ReadDart>('resa_ui_read_metrics');
    _igSubmit = lib.lookupFunction<_SubmitNative, _SubmitDart>('resa_ui_submit_command');
    _igAcquire = lib.lookupFunction<_AcquireNative, _AcquireDart>('resa_ui_acquire_batch');
    // Nu chem resa_ui_connect (crash). Citesc handle-ul real din memoria
    // motorului: simbolul resa_ui_abi_version e la 0xa70998, iar handle-ul
    // global la 0x1f4e2a0 in alyn_resa.
    final sym = lib.lookup('resa_ui_abi_version');
    final base = sym.address - 0xa70998;
    _igBase = base;
    final hp = ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(base + 0x1f4e2a0);
    // Varianta STABILA: nu chem resa_ui_connect (crash). Pun doar marcator
    // non-null ca is_attached sa dea true, fara a-l folosi in FFI.
    final real = hp.value;
    if (real == ffi.Pointer<ffi.Void>.fromAddress(0)) {
      // Context generos + vtable cu 16 sloturi pastrate global: nativul
      // scrie/citeste in context, unul de 24 bytes dadea EXC_BAD_ACCESS.
      _igCb = ffi.NativeCallable<ffi.Void Function()>.listener(() {});
      final vt = malloc(0x80).cast<ffi.Pointer<ffi.Void>>();
      for (int i = 0; i < 16; i++) vt[i] = _igCb!.nativeFunction.cast<ffi.Void>();
      _igVtKept = vt.cast<ffi.Void>();
      final ctx = malloc(0x100).cast<ffi.Uint64>();
      ctx[0] = vt.address;
      for (int i = 1; i < 32; i++) ctx[i] = 0;
      _igCtxKept = ctx.cast<ffi.Void>();
      _igConnect = lib.lookupFunction<_ConnectNative, _ConnectDart>('resa_ui_connect');
      _igHandle = _igConnect!(1, _igCtxKept!);
    } else {
      _igHandle = real;
    }
    _igAttached = 1;
  } catch (_) {}
}

// Citeste evenimentele din batch-ul UI al engine-ului (dialoguri etc.).
String _igDocs = '';

void _igDump(String content) {
  final paths = <String>[
    if (_igDocs.isNotEmpty) '$_igDocs/logcat/batch_dump.txt',
    '${Directory.current.path}/batch_dump.txt',
  ];
  for (final p in paths) {
    try {
      File(p).writeAsStringSync(content);
      return;
    } catch (_) {}
  }
}

void _igPollBatch() {
  try {
    if (_igDocs.isEmpty) {
      _installRoot().then((v) {
        _igDocs = v;
      }).catchError((_) {});
    }
    if (_igAcquire == null || _igBase == 0) {
      _igDump('NO_ACQUIRE base=$_igBase');
      return;
    }
    // Recitest handle-ul: la pornire putea fi 0, iar nativul il seteaza mai tarziu.
    final hp = ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(_igBase + 0x1f4e2a0);
    final handle = hp.value;
    if (handle == ffi.Pointer<ffi.Void>.fromAddress(0)) {
      _igDump('NO_HANDLE base=$_igBase');
      return;
    }
    final batch = _igAcquire!(handle);
    if (batch == ffi.Pointer<ffi.Void>.fromAddress(0)) {
      _igDump('NO_BATCH handle=${handle.address}');
      return;
    }
    final raw = batch.cast<ffi.Uint8>().asTypedList(0x40);
    final w = batch.cast<ffi.Uint64>();
    final dbgRaw = StringBuffer('HANDLE=${handle.address} BATCH=${batch.address}\n'
        'RAW ${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}\n'
        'WORDS ${List.generate(8, (i) => w[i].toRadixString(16)).join(' ')}\n');
    try {
      _igDump(dbgRaw.toString());
    } catch (_) {}
    final start = ffi.Pointer<ffi.Uint8>.fromAddress(w[5]); // +0x28
    final end = w[7]; // +0x38
    final count = (end - w[5]) ~/ 0x30;
    if (count <= 0 || count > 64) {
      try {
        _igDump(dbgRaw.toString() + 'COUNT=$count\n');
      } catch (_) {}
      return;
    }
    final dbg = StringBuffer();
    for (int k = 0; k < count; k++) {
      final rec = ffi.Pointer<ffi.Uint8>.fromAddress(w[5] + k * 0x30);
      final raw = rec.asTypedList(0x30);
      dbg.writeln('$k ${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      // Cauta siruri ASCII in inregistrare.
      final strs = <String>[];
      final buf = StringBuffer();
      for (final c in raw) {
        if (c >= 32 && c < 127) {
          buf.writeCharCode(c);
        } else {
          if (buf.length >= 4) strs.add(buf.toString());
          buf.clear();
        }
      }
      if (buf.length >= 4) strs.add(buf.toString());
      if (strs.isEmpty) continue;
      // Un dialog are de obicei id mic (1 = DIALOG_LOGIN) si text.
      final id = rec.cast<ffi.Uint32>().value;
      if (id == 0 || id > 100000) continue;
      _igDlgId = id;
      _igDlgTitle = strs.length > 1 ? strs[1] : 'BLACK MOLDOW';
      _igDlgText = strs.length > 2 ? strs[2] : strs[0];
      _igDlgButtons = <String>[
        if (strs.length > 3) strs[3] else 'OK',
        if (strs.length > 4) strs[4] else 'Anulare',
      ];
      _igInput = '';
      _igDialogOpen = true;
      window.scheduleFrame();
      try {
        _igDump(dbg.toString());
      } catch (_) {}
      return;
    }
    try {
      _igDump(dbg.toString());
    } catch (_) {}
  } catch (_) {}
}

// Raspuns dialog SA-MP: buton, id dialog, text (ca in Android SendDialogResponse).
void _igSendDialogResponse(int button, String input) {
  try {
    final bytes = utf8.encode(input);
    final p = mallocTyped(bytes.length + 1);
    for (int i = 0; i < bytes.length; i++) p[i] = bytes[i];
    p[bytes.length] = 0;
    for (final t in <int>[1, 62, 246, _igDlgId]) {
      _igSubmit?.call(_igHandle?.address ?? 0, t, p.cast<ffi.Void>(), bytes.length);
    }
  } catch (_) {}
  try {
    window.sendPlatformMessage(
        _igChan,
        _call('message', <String, Object?>{
          'dialogResponse': true,
          'button': button,
          'dialogId': _igDlgId,
          'input': input,
          'message': input,
        }),
        (_) {});
  } catch (_) {}
}

void _igSendInput(String s) {
  if (s.isEmpty) return;
  try {
    final bytes = utf8.encode(s);
    final p = mallocTyped(bytes.length + 1);
    for (int i = 0; i < bytes.length; i++) p[i] = bytes[i];
    p[bytes.length] = 0;
    // Tipuri de comanda incercate: 1 (dialog response), 246 (RPC auth login
    // din clientul Android), 62 (RPC_DialogResponse SA-MP).
    for (final t in <int>[1, 246, 62]) {
      _igSubmit?.call(_igHandle?.address ?? 0, t, p.cast<ffi.Void>(), bytes.length);
    }
  } catch (_) {}
  try {
    window.sendPlatformMessage(
        _igChan, _call('message', <String, Object?>{'message': s, 'text': s}), (_) {});
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
    try {
      final log = File('${Directory.current.path}/Documents/logcat/dart_methods.txt');
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $method ${args.toString()}\n',
          mode: FileMode.append);
    } catch (_) {}
    // Dialog SA-MP: titlu + text + butoane + camp de introducere.
    if (args is Map) {
      final cap = args['caption'] ?? args['title'] ?? args['header'];
      final txt = args['text'] ?? args['message'] ?? args['info'];
      final did = args['dialogId'] ?? args['dialog_id'] ?? args['id'];
      final btn1 = args['button1'] ?? args['leftButton'];
      final btn2 = args['button2'] ?? args['rightButton'];
      if (cap is String || txt is String) {
        if (cap is String) _igDlgTitle = cap;
        if (txt is String) _igDlgText = txt;
        if (did is int) _igDlgId = did;
        _igDlgButtons = <String>[
          if (btn1 is String && btn1.isNotEmpty) btn1 else 'OK',
          if (btn2 is String && btn2.isNotEmpty) btn2 else 'Anulare',
        ];
        _igDlgHasInput = method.toLowerCase().contains('password') ||
            txt.toString().toLowerCase().contains('parol');
        _igInput = '';
        _igDialogOpen = true;
        window.scheduleFrame();
        if (reply != null) reply(null);
        return;
      }
    }
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

void _igCircle(Canvas c, Offset center, double radius, String label,
    {Color fill = const Color(0x55222226), Color ring = const Color(0xAAFFFFFF)}) {
  c.drawCircle(center, radius, Paint()..color = fill);
  c.drawCircle(center, radius, Paint()
    ..color = ring..style = PaintingStyle.stroke..strokeWidth = dp(2));
  c.drawCircle(center, radius * 0.78, Paint()
    ..color = const Color(0x18FFFFFF)..style = PaintingStyle.stroke..strokeWidth = dp(0.7));
  _txt(c, label, center.dx - radius, center.dy - dp(6), label.length > 3 ? dp(9) : dp(11),
      _cWhite, align: TextAlign.center, width: radius * 2);
}

void _igPill(Canvas c, Rect r, String label, {bool gold = false}) {
  _round(c, r, r.height / 2, gold ? const Color(0x55401200) : const Color(0x55222226),
      stroke: gold ? const Color(0xEEFFC62E) : const Color(0x99FFFFFF), sw: dp(1.2));
  _txt(c, label, r.left, r.top + r.height * 0.27, dp(9), gold ? _cGold : _cWhite,
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
  // Reproducere 1:1 a login_layout.xml din proiectul Android.
  // Fundal: @drawable/auth_bg
  c.drawRect(Offset.zero & Size(_w, _h), Paint()..color = const Color(0xFF0B0B10));
  if (_igBg != null) {
    c.drawImageRect(_igBg!, Rect.fromLTWH(0, 0, _igBg!.width.toDouble(), _igBg!.height.toDouble()),
        Offset.zero & Size(_w, _h), Paint());
  }
  // @drawable/auth_grd : gradient #EA161C24 -> #EB241416, unghi 135
  for (int i = 0; i < 32; i++) {
    final t = i / 31;
    c.drawRect(Rect.fromLTWH(0, _h * t, _w, _h / 31 + 1),
        Paint()..color = Color.fromARGB(0xEA, 0x16 + ((0x24 - 0x16) * t).round(),
            0x1c - ((0x1c - 0x14) * t).round(), 0x24 - ((0x24 - 0x16) * t).round()));
  }
  c.drawRect(Offset.zero & Size(_w, _h), Paint()..color = const Color(0x66000000));

  // Texte sus-stanga (muller_bold 20sp)
  _igText(c, 'Bine ai venit pe', dp(22), dp(22), dp(20), const Color(0xFFFFFFFF), 'MullerBd');
  _igText(c, _igDlgTitle, dp(22), dp(48), dp(20), const Color(0xFFFF0000), 'MullerBd');
  if (_igDlgText.isNotEmpty) {
    _igText(c, _igDlgText, dp(22), dp(76), dp(11), const Color(0xFFE0E0E0), 'MontserratMd',
        width: math.max(dp(200), _w / 2 - dp(40)));
  }

  // Personaj stanga (170x241 dp, @drawable/auth_skin)
  final skin = Rect.fromLTWH(dp(12), _h - dp(241), dp(170), dp(241));
  if (_igSkin != null) {
    c.drawImageRect(_igSkin!, Rect.fromLTWH(0, 0, _igSkin!.width.toDouble(), _igSkin!.height.toDouble()),
        skin, Paint());
  } else {
    _round(c, skin, dp(4), const Color(0xFF16161C), stroke: const Color(0x33FFFFFF));
  }

  // Bara HP (64x9 dp) deasupra personajului
  final hp = Rect.fromLTWH(skin.left, skin.top - dp(15), dp(64), dp(9));
  _round(c, hp, 0, const Color(0xFF4A0D11), stroke: const Color(0xFF000000), sw: dp(2));
  c.drawRect(Rect.fromLTWH(hp.left + dp(2), hp.top + dp(2), dp(41), dp(5)),
      Paint()..color = const Color(0xFFBA121C));
  // Nickname deasupra HP
  _igText(c, _nick, skin.left, hp.top - dp(21), dp(14), const Color(0xFFFFFFFF), 'MontserratMd');

  // Divider vertical centru (@drawable/auth_divider)
  final dx = _w / 2 - dp(2.5);
  for (int i = 0; i < 16; i++) {
    final t = i / 15;
    final a = (0x33 * math.sin(t * math.pi)).round();
    c.drawRect(Rect.fromLTWH(dx, _h * t, dp(5), _h / 16 + 1),
        Paint()..color = Color.fromARGB(a, 255, 255, 255));
  }

  // Formular dreapta: 263 dp latime, marginEnd 20 dp, centrat vertical
  final fw = dp(263);
  final fx = _w - fw - dp(20);
  final fh = dp(186);
  final fy = (_h - fh) / 2;

  // @drawable/auth_input : #8014161C, border #BA121C 1dp, radius 6dp
  Rect field(double y) => Rect.fromLTWH(fx, y, fw, dp(50));
  final f1 = field(fy);
  _round(c, f1, dp(6), const Color(0x8014161C), stroke: const Color(0xFFBA121C), sw: dp(1));
  _igText(c, 'Login', f1.left + dp(9), f1.top + dp(5), dp(10), const Color(0x80FFFFFF), 'MontserratMd');
  _igText(c, _nick, f1.left + dp(10), f1.top + dp(17), dp(13), const Color(0xFFFFFFFF), 'MontserratMd');

  final f2 = field(f1.bottom + dp(12));
  _round(c, f2, dp(6), const Color(0x8014161C), stroke: const Color(0xFFBA121C), sw: dp(1));
  _igText(c, 'Parola', f2.left + dp(9), f2.top + dp(5), dp(10), const Color(0x80FFFFFF), 'MontserratMd');
  _igText(c, '*' * _igInput.length, f2.left + dp(10), f2.top + dp(17), dp(15),
      const Color(0xFFFFFFFF), 'MontserratMd');
  // Cursor
  if (_igFrame % 60 < 30) {
    final cx = f2.left + dp(10) + dp(_igInput.length * 15 * 0.62);
    c.drawRect(Rect.fromLTWH(cx, f2.top + dp(17), dp(1.5), dp(18)),
        Paint()..color = const Color(0xFFBA121C));
  }

  _igText(c, 'Recuperare parolă?', f2.right - dp(100), f2.bottom + dp(6), dp(10),
      const Color(0xB0B0B0), 'MontserratMd');

  // @drawable/auth_enter_btn + text "Intră" (muller_bold 17sp)
  final btn = Rect.fromLTWH(fx, f2.bottom + dp(30), fw, dp(50));
  _round(c, btn, dp(6), const Color(0xFFBA121C), stroke: const Color(0xFFFFFFFF), sw: dp(1.5));
  _igText(c, _igDlgButtons.isNotEmpty ? _igDlgButtons[0] : 'Intră', btn.left, btn.top + dp(14),
      dp(17), const Color(0xFFFFFFFF), 'MullerBd', align: TextAlign.center, width: btn.width);
  _igDlgOK = btn;
  _igDlgCancel = Rect.fromLTWH(fx, btn.bottom + dp(8), fw, dp(28));
  _igPill(c, _igDlgCancel, _igDlgButtons.length > 1 ? _igDlgButtons[1].toUpperCase() : 'ANULARE');

  // Tastatura QWERTY in partea de jos (folosita la introducerea parolei).
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
  final kw = dp(30), kh = dp(28), gap = dp(3);
  final y0 = _h - 3 * (kh + gap) - dp(4);
  for (int r = 0; r < rows.length; r++) {
    final row = rows[r];
    final tw = row.length * kw + (row.length - 1) * gap;
    final x0 = (_w - tw) / 2;
    for (int i = 0; i < row.length; i++) {
      final kr = Rect.fromLTWH(x0 + i * (kw + gap), y0 + r * (kh + gap), kw, kh);
      _round(c, kr, dp(4), const Color(0x3AFFFFFF), stroke: const Color(0x22FFFFFF));
      _txt(c, row[i], kr.left, kr.top + dp(7), dp(11), _cWhite,
          align: TextAlign.center, width: kw);
      _igKeyRects.add(kr);
      _igKeyLabels.add(row[i]);
    }
  }
}

void _igText(Canvas c, String s, double x, double y, double size, Color color, String family,
    {TextAlign align = TextAlign.left, double? width}) {
  final pb = ParagraphBuilder(ParagraphStyle(textAlign: align))
    ..pushStyle(TextStyle(fontFamily: family, fontSize: size, color: color, height: 1))
    ..addText(s)
    ..pop();
  final p = pb.build()..layout(ParagraphConstraints(width: width ?? 2000));
  c.drawParagraph(p, Offset(x, y));
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

  // Controalele touch (stick, sarit, lovit etc.) sunt desenate de engine.
  // Nu mai suprapunem butoane proprii peste ele.
  // Fara buton LOGIN propriu � las doar dialogurile reale ale jocului.
  _igDlgLoginBtn = Rect.zero;

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
    final p = Offset(d.physicalX, d.physicalY);
    if (d.change != PointerChange.down) continue;
    if (_igDialogOpen) {
      if (_igDlgOK.contains(p)) {
        final s = _igInput.trim();
        if (s.isNotEmpty) {
          _password = s;
          _savePassword(s);
        }
        _igSendDialogResponse(1, s);
        _igDialogOpen = false;
        _igInput = '';
      } else if (_igDlgCancel.contains(p)) {
        _igSendDialogResponse(0, '');
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
    if ((Offset(dp(179), _h - dp(53)) - p).distance < dp(36)) {
      _igChatOpen = !_igChatOpen;
    } else if ((Offset(dp(224), _h - dp(53)) - p).distance < dp(36)) {
      _igScoreOpen = !_igScoreOpen;
    }
    window.scheduleFrame();
  }
}

void _igHandshake() {
  // Vechiul UI trimitea aceste metode catre nativ la pornire. Daca sunt
  // trimise prea devreme, mesajul se pierde si motorul face timeout (~secunde)
  // si revine in launcher. De aceea le retrimit periodic.
  _send(_igChan, _call('getConfiguration', <String, Object?>{})).catchError((_) {});
  void sendReady() {
    for (final st in <String>['starting', 'ready']) {
      _send(_igChan, _call('uiReady', <String, Object?>{
        'state': st,
        'abiVersion': 1,
      })).catchError((_) {});
    }
  }

  sendReady();
  Timer(const Duration(milliseconds: 500), sendReady);
  Timer(const Duration(seconds: 1), sendReady);
  Timer(const Duration(seconds: 2), sendReady);
  Timer(const Duration(seconds: 4), sendReady);
}

@pragma('vm:entry-point')
void ingameMain() {
  _igInitNative();
  _igLoadAssets();
  _readNick(); // isolate separat: incarc nick_name + server_password din plist
  _igDialogOpen = false; // NU mai afisam login propriu; doar dialogurile reale ale serverului
  _igHandshake();
  window.onPlatformMessage = _igMsg;
  window.onPointerDataPacket = _igPointer;
  window.onDrawFrame = () {
    _igFrame++;
    if (_igFrame % 10 == 0 && !_igDialogOpen) _igPollBatch();
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




