// zcm: the predictor of each level: which models run, how the memory
// budget is split between them, the mixers and the APM (SSE) chain.

import 'zcm_byte_models.dart';
import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';
import 'zcm_x86.dart';

/// What a level turns on. Derived only from the level and the budget
/// stored in the stream, so the decoder builds the same predictor.
final class ZcmLevelSpec {
  final int level;
  final List<int> orders;
  final bool rich;
  final bool match;
  final int matchMinS;
  final int matchMinL;
  final bool word; // on text blocks
  final bool wordAlways;
  final bool sparse;
  final bool indirect;
  final bool record;
  final bool exe;
  final int selectors; // mixer weight set selectors
  final int apms; // 0 to 4
  final bool fast; // FastOrderModel instead of the bit history maps
  final bool bh; // byte history inputs in the order-n context map
  final int ppmdOrder; // 0: no PPMd byte model
  final bool charGroup;
  final bool dmc;
  final bool fullIndirect;

  const ZcmLevelSpec({
    required this.level,
    required this.orders,
    this.rich = true,
    this.match = true,
    this.matchMinS = 6,
    this.matchMinL = 0,
    this.word = false,
    this.wordAlways = false,
    this.sparse = false,
    this.indirect = false,
    this.record = false,
    this.exe = false,
    this.selectors = 1,
    this.apms = 1,
    this.fast = false,
    this.bh = false,
    this.ppmdOrder = 0,
    this.charGroup = false,
    this.dmc = false,
    this.fullIndirect = false,
  });

  static ZcmLevelSpec of(int level) {
    switch (level) {
      case 1:
        return const ZcmLevelSpec(
            level: 1, orders: [1, 2, 3, 4, 6], fast: true, apms: 1);
      case 2:
        return const ZcmLevelSpec(
            level: 2, orders: [2, 3, 4, 6], rich: false, selectors: 2, apms: 2);
      case 3:
        return const ZcmLevelSpec(
            level: 3,
            orders: [2, 3, 4, 6],
            word: true,
            exe: true,
            selectors: 3,
            apms: 3);
      case 4:
        return const ZcmLevelSpec(
            level: 4,
            orders: [2, 3, 4, 5, 6, 8],
            matchMinL: 16,
            word: true,
            sparse: true,
            exe: true,
            selectors: 4,
            apms: 3);
      case 5:
        return const ZcmLevelSpec(
            level: 5,
            orders: [2, 3, 4, 5, 6, 8],
            matchMinL: 16,
            word: true,
            sparse: true,
            indirect: true,
            exe: true,
            selectors: 4,
            apms: 4);
      case 6:
        return const ZcmLevelSpec(
            level: 6,
            orders: [2, 3, 4, 5, 6, 7, 8, 12],
            matchMinL: 20,
            word: true,
            sparse: true,
            indirect: true,
            record: true,
            exe: true,
            charGroup: true,
            selectors: 4,
            apms: 4);
      default:
        return ZcmLevelSpec(
            level: level,
            orders: level >= 8
                ? const [2, 3, 4, 5, 6, 7, 8, 12, 16, 24]
                : const [2, 3, 4, 5, 6, 7, 8, 12],
            matchMinL: level >= 8 ? 24 : 20,
            word: true,
            wordAlways: level >= 8,
            sparse: true,
            indirect: true,
            record: true,
            exe: true,
            bh: true,
            charGroup: true,
            dmc: level >= 8,
            fullIndirect: true,
            selectors: 6,
            apms: 4,
            ppmdOrder: level >= 9 ? 16 : 0);
    }
  }
}

/// The byte history size for a budget.
int zcmBufferBytes(int budgetBytes) {
  var b = floorPow2(budgetBytes ~/ 8);
  if (b > (64 << 20)) b = 64 << 20;
  if (b < (1 << 16)) b = 1 << 16;
  return b;
}

/// Predicts the bits of a stream. One instance per independent segment.
final class ZcmPredictor {
  final ZcmLevelSpec spec;
  final ZcmState s;
  final ZcmOrders _orders;
  final MatchModel? _match;
  final WordModel? _word;
  final SparseModel? _sparse;
  final IndirectModel? _indirect;
  final RecordModel? _record;
  final ZcmModel? _exe;
  final CharGroupModel? _charGroup;
  final DmcModel? _dmc;
  final PpmdByteModel? _ppmd;
  final LstmByteModel? _lstm;
  final List<Mixer?> _mixers = List<Mixer?>.filled(ZcmBlockType.count, null);
  final List<List<ZcmModel>?> _active =
      List<List<ZcmModel>?>.filled(ZcmBlockType.count, null);
  Mixer? _last;
  final List<List<ZcmMixerContexts>?> _extra =
      List<List<ZcmMixerContexts>?>.filled(ZcmBlockType.count, null);
  final Apm? _a1, _a2, _a3, _a4;
  int _pr = 2048;
  int _misses = 0;
  int _prMix = 2048;

  /// Bytes the tables of this predictor use (for tests and reports).
  final int tableBytes;

  factory ZcmPredictor(int level, int budgetBytes,
      {int lstmCells = 0, int lstmLayers = 1, int lstmHorizon = 10}) {
    final spec = ZcmLevelSpec.of(level);
    final bufBytes = zcmBufferBytes(budgetBytes);
    final matchEntries = spec.match ? floorPow2(budgetBytes ~/ 64) : 0;
    var rest = budgetBytes - bufBytes - matchEntries * 8 - (2 << 20);
    var ppmdBytes = 0;
    if (spec.ppmdOrder > 0) {
      ppmdBytes = floorPow2(rest ~/ 4);
      if (ppmdBytes > (1 << 31)) ppmdBytes = 1 << 31;
      rest -= ppmdBytes;
    }
    // Shares of the context map memory (in contexts).
    final wo = spec.orders.length * 2;
    final ww = spec.word ? 12 : 0;
    final ws = spec.sparse ? 4 : 0;
    final wi = spec.indirect ? 3 : 0;
    final wr = spec.record ? 3 : 0;
    final we = spec.exe ? 4 : 0;
    final wg = spec.charGroup ? 3 : 0;
    final wd = spec.dmc ? 2 : 0;
    final total = wo + ww + ws + wi + wr + we + wg + wd;
    int share(int w) => w == 0 ? 0 : floorPow2((rest * w) ~/ total);
    return ZcmPredictor._(spec, bufBytes, matchEntries, share(wo), share(ww),
        share(ws), share(wi), share(wr), share(we), share(wg),
        wd == 0 ? 0 : (rest * wd) ~/ total, ppmdBytes,
        lstmCells, lstmLayers, lstmHorizon);
  }

  ZcmPredictor._(this.spec, int bufBytes, int matchEntries, int bo, int bw,
      int bs, int bi, int br, int be, int bg, int bd, int ppmdBytes, int lstmCells,
      int lstmLayers, int lstmHorizon)
      : s = ZcmState(bufBytes),
        _ppmd = ppmdBytes > 0 ? PpmdByteModel(spec.ppmdOrder, ppmdBytes) : null,
        _lstm = lstmCells > 0
            ? LstmByteModel(lstmCells, lstmLayers, lstmHorizon)
            : null,
        _orders = spec.fast
            ? FastOrderModel(spec.orders, bo, twoInputs: false)
            : OrderModel(spec.orders, bo, rich: spec.rich, bh: spec.bh),
        _match = spec.match
            ? MatchModel(matchEntries, bufBytes,
                minS: spec.matchMinS,
                minL: spec.matchMinL > 0 ? spec.matchMinL : 1 << 30)
            : null,
        _word = spec.word
            ? WordModel(bw, contexts: spec.level <= 4 ? 10 : 16)
            : null,
        _sparse = spec.sparse ? SparseModel(bs) : null,
        _indirect =
            spec.indirect ? IndirectModel(bi, full: spec.fullIndirect) : null,
        _charGroup = spec.charGroup ? CharGroupModel(bg) : null,
        _dmc = spec.dmc ? DmcModel(bd) : null,
        _record = spec.record ? RecordModel(br) : null,
        _exe = spec.exe
            ? (spec.level >= 4
                ? X86Model(be, full: spec.level >= 6)
                : ExeModel(be))
            : null,
        _a1 = spec.apms >= 1 ? Apm(256 * 8) : null,
        _a2 = spec.apms >= 2 ? Apm(65536) : null,
        _a3 = spec.apms >= 3 ? Apm(65536) : null,
        _a4 = spec.apms >= 4 ? Apm(65536) : null,
        tableBytes = bufBytes +
            matchEntries * 8 +
            bo +
            bw +
            bs +
            bi +
            br +
            be +
            bg +
            (spec.dmc ? DmcModel.nodesFor(bd) * 12 : 0) +
            ppmdBytes;

  List<ZcmModel> _modelsFor(int type) {
    final l = <ZcmModel>[_orders];
    if (_match != null) l.add(_match);
    if (_word != null && (type == ZcmBlockType.text || spec.wordAlways)) {
      l.add(_word);
    }
    if (_sparse != null) l.add(_sparse);
    if (_indirect != null) l.add(_indirect);
    if (_record != null) l.add(_record);
    if (_exe != null && type == ZcmBlockType.exe) l.add(_exe);
    if (_charGroup != null) l.add(_charGroup);
    if (_dmc != null) l.add(_dmc);
    if (_ppmd != null) l.add(_ppmd);
    if (_lstm != null) l.add(_lstm);
    return l;
  }

  Mixer _mixerFor(int type, List<ZcmModel> models) {
    var n = 1;
    for (final m in models) {
      n += m.inputs;
    }
    final sizes = <int>[256];
    final sel = spec.selectors;
    if (sel >= 2) sizes.add(64 * 8);
    if (sel >= 3) sizes.add(256);
    if (sel >= 4) sizes.add(16 * 4 * 8);
    if (sel >= 5) sizes.add(256);
    if (sel >= 6) sizes.add(1024);
    final extra = <ZcmMixerContexts>[];
    for (final m in models) {
      if (m is ZcmMixerContexts) {
        final x = m as ZcmMixerContexts;
        sizes.addAll(x.mixerContextSizes);
        extra.add(x);
      }
    }
    _extra[type] = extra;
    var w0 = (65536 * 12) ~/ n;
    if (w0 > 16384) w0 = 16384;
    return Mixer(n, sizes, finalContexts: 8, initWeight: w0);
  }

  /// Probability (12 bits) that the next bit is 1.
  int p() {
    final st = s;
    final y = st.y;
    final type = st.blockType;
    final last = _last;
    if (last != null) last.update(y);
    var models = _active[type];
    if (models == null) {
      models = _active[type] = _modelsFor(type);
      _mixers[type] = _mixerFor(type, models);
    }
    final m = _mixers[type]!;
    _last = m;
    for (var i = 0; i < models.length; i++) {
      models[i].mix(st, m);
    }
    m.add(256);
    final c0 = st.c0;
    final bpos = st.bpos;
    // Recent mispredictions of the final probability.
    final miss = (_pr >= 2048) != (y == 1) ? 1 : 0;
    _misses = ((_misses << 1) | miss) & 0xFFFF;
    final m3 = (_misses & 1) | ((_misses & 0xFE) != 0 ? 2 : 0) |
        ((_misses & 0xFF00) != 0 ? 4 : 0);
    m.set(c0);
    final ml = _match?.length ?? 0;
    final mq = ml == 0
        ? 0
        : (ml < 16 ? 1 + (ml >> 2) : (ml < 32 ? 5 : (ml < 64 ? 6 : 7)));
    final sel = spec.selectors;
    if (sel >= 2) m.set(mq << 3 | bpos);
    if (sel >= 3) m.set(st.c4 & 255);
    if (sel >= 4) {
      var h = _orders.hits;
      if (h > 15) h = 15;
      m.set(((h << 2) | (m3 & 3)) << 3 | bpos);
    }
    if (sel >= 5) m.set((st.c4 >> 8) & 255);
    if (sel >= 6) {
      final low = c0 & ((1 << bpos) - 1);
      final flag = (low == 0 || c0 == (2 << bpos) - 1) ? 1 : 0;
      m.set((st.c4 & 255) | (bpos > 5 ? 256 : 0) | flag << 9);
    }
    final extra = _extra[type]!;
    for (var i = 0; i < extra.length; i++) {
      extra[i].setMixerContexts(st, m);
    }
    m.setFinal(bpos);
    var pr = m.p();
    _prMix = pr;
    final c4 = st.c4;
    final a1 = _a1;
    if (a1 != null) {
      final p1 = a1.pp(y, pr, c0 | m3 << 8);
      final a2 = _a2;
      if (a2 == null) {
        pr = (pr * 3 + p1 + 2) >> 2;
      } else {
        final p2 = a2.pp(y, pr, (hash2(c4 & 0xFFFF, c0)) & 0xFFFF);
        final a3 = _a3;
        if (a3 == null) {
          pr = (pr * 2 + p1 + p2 + 2) >> 2;
        } else {
          final p3 = a3.pp(y, pr, (hash2(c4 & 0xFFFFFF, c0 + 256)) & 0xFFFF);
          final a4 = _a4;
          int pa;
          if (a4 == null) {
            pa = (pr + p2 + p3 * 2 + 2) >> 2;
          } else {
            final e = _match?.expectedByte ?? -1;
            final p4 = a4.pp(
                y, pr, e < 0 ? c0 : (hash3(e, mq, c0) & 0xFFFF));
            pa = (pr + p2 + p3 + p4 + 2) >> 2;
          }
          pr = (pa * 3 + p1 + 2) >> 2;
        }
      }
    }
    if (pr < 1) pr = 1;
    if (pr > 4095) pr = 4095;
    return _pr = pr;
  }

  /// The mixer output before the APM stages (for diagnostics).
  int get mixerOutput => _prMix;

  /// The last prediction returned by [p].
  int get last => _pr;

  /// Records the coded bit.
  @pragma('vm:prefer-inline')
  void update(int bit) => s.update(bit);
}
