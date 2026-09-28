// zcm: the predictor of each level: which models run, how the memory
// budget is split between them, the mixers and the final probability
// refinement (SSE).
//
// Level 1 has a predictor of its own (zcm_fast.dart); levels 2 to 9 are
// [ZcmPredictor], configured by [ZcmLevelSpec].

import 'dart:typed_data';

import 'zcm_audio.dart';
import 'zcm_byte_models.dart';
import 'zcm_components.dart';
import 'zcm_fast.dart';
import 'zcm_image.dart';
import 'zcm_match.dart';
import 'zcm_models.dart';
import 'zcm_sparse.dart';
import 'zcm_tables.dart';
import 'zcm_text.dart';
import 'zcm_words.dart';
import 'zcm_x86.dart';

/// A bit predictor of a zcm stream (one per independent segment).
abstract interface class ZcmBitPredictor {
  /// The shared history.
  ZcmState get s;

  /// Probability (16 bits) that the next bit is 1.
  int p();

  /// Records the coded bit.
  void update(int bit);

  /// Starts a segment of [type] with [info] (zcm_detect.dart).
  void setSegment(int type, int info);

  /// Bytes of the tables (for tests and reports).
  int get tableBytes;
}

/// The predictor of [level] with a memory budget of [budgetBytes].
ZcmBitPredictor zcmCreatePredictor(int level, int budgetBytes,
        {int lstmCells = 0, int lstmLayers = 1, int lstmHorizon = 10}) =>
    level == 1
        ? ZcmFastPredictor(budgetBytes)
        : ZcmPredictor(level, budgetBytes,
            lstmCells: lstmCells,
            lstmLayers: lstmLayers,
            lstmHorizon: lstmHorizon);

/// What a level turns on. Derived only from the level and the budget
/// stored in the stream, so the decoder builds the same predictor.
final class ZcmLevelSpec {
  final int level;
  final List<int> orders;
  final bool rich;
  final int matchMinS;
  final int matchMinL;
  final int wordContexts; // 0: none, 10 or 16: WordModel, 67: paq8px's
  final bool wordAlways; // the word model on binary data too
  final bool sparse;
  final bool sparseLight;
  final bool indirect;
  final bool fullIndirect;
  final bool record;
  final int exe; // 0: none, 1: ExeModel, 2: X86Model light, 3: full
  final int selectors; // mixer weight set selectors of the predictor
  final int apms; // 0 to 4: the APM chain; 5: the paq8px SSE chain
  final bool bh; // byte history inputs in the order-n context map
  final int ppmdOrder; // 0: no PPMd byte model
  final bool charGroup;
  final bool dmc;
  final int image; // 0: none, 1: light, 2: full image model
  final int audio; // 0: none, 1: light, 2: full, 3: paq8px's full set
  final bool chart;
  final bool nest;
  final bool xml;
  final int finalRate; // learning rate of the final mixer layer (16.16)
  final int finalRateMin;
  final int text; // paq8px TextModel: 0 none, 1 text segments, 2 and binary
  final int textSets; // its mixer weight set selectors (0 to 10)
  final int sparseMatch; // paq8px SparseMatchModel: 0 none, 1 binary, 2 all
  final int sparseBit; // paq8px SparseBitModel: 0 none, 1 binary, 2 all
  final bool linearPrediction; // paq8px LinearPredictionModel (binary)
  final int similarity; // paq8px SimilarityModelPair window (0: none)
  final bool pxMatch; // the paq8px match model instead of MatchModel
  final bool gainGate; // PPMd and DMC inputs only while they gain

  const ZcmLevelSpec({
    required this.level,
    required this.orders,
    this.rich = true,
    this.matchMinS = 6,
    this.matchMinL = 0,
    this.wordContexts = 0,
    this.wordAlways = false,
    this.sparse = false,
    this.sparseLight = false,
    this.indirect = false,
    this.fullIndirect = false,
    this.record = false,
    this.exe = 0,
    this.selectors = 1,
    this.apms = 1,
    this.bh = false,
    this.ppmdOrder = 0,
    this.charGroup = false,
    this.dmc = false,
    this.image = 0,
    this.audio = 0,
    this.chart = false,
    this.nest = false,
    this.xml = false,
    this.finalRate = 8 << 16,
    this.finalRateMin = 2 << 16,
    this.text = 0,
    this.textSets = 10,
    this.sparseMatch = 0,
    this.sparseBit = 0,
    this.linearPrediction = false,
    this.similarity = 0,
    this.pxMatch = false,
    this.gainGate = false,
  });

  static ZcmLevelSpec of(int level) {
    switch (level) {
      case 2:
        return const ZcmLevelSpec(
            level: 2,
            orders: [2, 3, 4, 6],
            rich: false,
            selectors: 2,
            apms: 2,
            finalRate: 16 << 16);
      case 3:
        return const ZcmLevelSpec(
            level: 3,
            orders: [2, 3, 4, 6],
            rich: false,
            wordContexts: 5,
            exe: 1,
            image: 1,
            audio: 1,
            selectors: 3,
            apms: 2,
            finalRate: 16 << 16);
      case 4:
        return const ZcmLevelSpec(
            level: 4,
            orders: [2, 3, 4, 6],
            rich: false,
            matchMinL: 16,
            wordContexts: 10,
            sparse: true,
            sparseLight: true,
            exe: 2,
            image: 1,
            audio: 1,
            selectors: 3,
            apms: 2,
            finalRate: 16 << 16);
      case 5:
        return const ZcmLevelSpec(
            level: 5,
            orders: [2, 3, 4, 6],
            rich: false,
            matchMinL: 16,
            wordContexts: 16,
            sparse: true,
            sparseLight: true,
            exe: 2,
            image: 1,
            audio: 1,
            selectors: 3,
            apms: 4,
            finalRate: 24 << 16,
            finalRateMin: 3 << 16);
      case 6:
        return const ZcmLevelSpec(
            level: 6,
            orders: [2, 3, 4, 5, 6, 7, 8, 12],
            matchMinL: 20,
            wordContexts: 16,
            sparse: true,
            indirect: true,
            record: true,
            exe: 3,
            charGroup: true,
            image: 2,
            audio: 2,
            selectors: 6,
            apms: 4);
      default:
        final x = zcmExperiment;
        return ZcmLevelSpec(
            level: level,
            orders: const [2, 3, 4, 5, 6, 7, 8, 12],
            matchMinL: level >= 8 ? 24 : 20,
            wordContexts: 67,
            wordAlways: level >= 8,
            sparse: true,
            indirect: true,
            fullIndirect: true,
            record: true,
            exe: 3,
            bh: true,
            charGroup: true,
            image: 2,
            audio: level >= 8 ? 3 : 2, // media agent: paq8px's set at 8, 9
            selectors: 7,
            apms: 5,
            dmc: level >= 9,
            ppmdOrder: level >= 9 ? 16 : 0,
            text: level >= 8 ? 1 : 0,
            sparseMatch: x.contains('sm') ? 1 : 0,
            sparseBit: x.contains('sb') ? 1 : 0,
            linearPrediction: x.contains('lp'),
            similarity: level >= 9 || x.contains('sim') ? 2048 : 0,
            gainGate: !x.contains('nogate'),
            pxMatch: true);
    }
  }
}

/// Measurement switches for tool/zcm_bench.dart only (never set by the
/// codec: the decoder must build the same predictor from the header).
String zcmExperiment = '';

/// The byte history size for a budget.
int zcmBufferBytes(int budgetBytes) {
  var b = floorPow2(budgetBytes ~/ 8);
  if (b > (64 << 20)) b = 64 << 20;
  if (b < (1 << 16)) b = 1 << 16;
  return b;
}

/// Predicts the bits of a stream (levels 2 to 9).
final class ZcmPredictor implements ZcmBitPredictor {
  final ZcmLevelSpec spec;
  @override
  final ZcmState s;
  final ZcmOrders _orders;
  final ZcmMatchInfo _match;
  final ZcmModel? _word;
  final TextModel? _text;
  final SparseMatchModel? _sparseMatch;
  final SparseBitModel? _sparseBit;
  final LinearPredictionModel? _lp;
  final SimilarityModel? _sim;
  final SparseModel? _sparse;
  final IndirectModel? _indirect;
  final RecordModel? _record;
  final ZcmModel? _exe;
  final CharGroupModel? _charGroup;
  final DmcModel? _dmc;
  final ChartModel? _chart;
  final NestModel? _nest;
  final XmlModel? _xml;
  final PpmdByteModel? _ppmd;
  final LstmByteModel? _lstm;
  final int _imageBytes;
  final int _audioBytes;
  ImageModel? _image;
  ZcmBitImageModel? _bitImage; // media agent: 1 and 4 bit images
  AudioModel? _audio;
  final List<Mixer?> _mixers = List<Mixer?>.filled(ZcmBlockType.count, null);
  final List<List<ZcmModel>?> _active =
      List<List<ZcmModel>?>.filled(ZcmBlockType.count, null);
  Mixer? _last;
  final List<List<ZcmMixerContexts>?> _extra =
      List<List<ZcmMixerContexts>?>.filled(ZcmBlockType.count, null);
  final Apm? _a1, _a2, _a3, _a4;
  final int _sseBits;
  _SsePx? _sseText, _sseGeneric, _sseImage;
  int _pr = 2048;
  int _misses = 0;
  int _prMix = 2048;

  @override
  final int tableBytes;

  /// [budgetBytes]: every table is sized from it (see the split below).
  factory ZcmPredictor(int level, int budgetBytes,
      {int lstmCells = 0, int lstmLayers = 1, int lstmHorizon = 10}) {
    final spec = ZcmLevelSpec.of(level);
    final bufBytes = zcmBufferBytes(budgetBytes);
    final matchEntries = floorPow2(budgetBytes ~/ 64);
    final sseBits = spec.apms >= 5 ? _SsePx.bitsFor(budgetBytes) : 0;
    final sseBytes = spec.apms >= 5 ? _SsePx.bytesFor(sseBits) * 2 : 0;
    // Image and audio models are built on their first segment only; each
    // may use a quarter of the budget on top of the other tables.
    final mediaBytes = budgetBytes ~/ 4;
    final imageBytes = spec.image > 0 ? mediaBytes : 0;
    final audioBytes = spec.audio > 0 ? mediaBytes : 0;
    // The match model: paq8px's (positions, its context map, its large
    // stationary map and fixed maps) or the simple one (two tables).
    final matchBytes = spec.pxMatch
        ? PxMatchModel.tableBytes(
                matchEntries * 8, zcmHashBitsFor(matchEntries * 4, 42)) +
            floorPow2(matchEntries * 4) +
            64
        : floorPow2(matchEntries) * 8;
    var rest = budgetBytes - bufBytes - matchBytes - (1 << 20) - sseBytes;
    if (rest < (256 << 10)) rest = 256 << 10;
    // PPMd (level 9) takes a quarter of the budget on top of the rest.
    var ppmdBytes = 0;
    if (spec.ppmdOrder > 0 && budgetBytes >= (16 << 20)) {
      ppmdBytes = floorPow2(budgetBytes ~/ 4);
      if (ppmdBytes > (1 << 31)) ppmdBytes = 1 << 31;
    }
    // Shares of the context map memory (in contexts).
    final wo = spec.orders.length * 2;
    final ww = spec.wordContexts == 0 ? 0 : (spec.wordContexts > 16 ? 24 : 12);
    final ws = spec.sparse ? 4 : 0;
    final wi = spec.indirect ? 3 : 0;
    final wr = spec.record ? 3 : 0;
    final we = spec.exe > 0 ? 4 : 0;
    final wg = spec.charGroup ? 3 : 0;
    // DMC needs at least 3 MiB of nodes: only with larger budgets.
    final dmc = spec.dmc && budgetBytes >= (16 << 20);
    final wd = dmc ? 2 : 0;
    final wc = spec.chart ? 6 : 0;
    final wn = spec.nest ? 2 : 0;
    final wx = spec.xml ? 1 : 0;
    final wt = spec.text > 0 ? 10 : 0;
    final wsm = spec.sparseMatch > 0 ? 2 : 0;
    final wsb = spec.sparseBit > 0 ? 3 : 0;
    final wsi = spec.similarity > 0 ? 3 : 0;
    final total = wo +
        ww +
        ws +
        wi +
        wr +
        we +
        wg +
        wd +
        wc +
        wn +
        wx +
        wt +
        wsm +
        wsb +
        wsi;
    int share(int w) => w == 0 ? 0 : floorPow2((rest * w) ~/ total);
    return ZcmPredictor._(
        spec,
        bufBytes,
        matchEntries,
        matchBytes,
        share(wo),
        share(ww),
        share(ws),
        share(wi),
        share(wr),
        share(we),
        share(wg),
        wd == 0 ? 0 : (rest * wd) ~/ total,
        share(wc),
        share(wn),
        share(wx),
        share(wt),
        share(wsm),
        share(wsb),
        share(wsi),
        ppmdBytes,
        lstmCells,
        lstmLayers,
        lstmHorizon,
        sseBits,
        sseBytes,
        imageBytes,
        audioBytes);
  }

  ZcmPredictor._(
      this.spec,
      int bufBytes,
      int matchEntries,
      int matchBytes,
      int bo,
      int bw,
      int bs,
      int bi,
      int br,
      int be,
      int bg,
      int bd,
      int bc,
      int bn,
      int bx,
      int bt,
      int bsm,
      int bsb,
      int bsi,
      int ppmdBytes,
      int lstmCells,
      int lstmLayers,
      int lstmHorizon,
      this._sseBits,
      int sseBytes,
      this._imageBytes,
      this._audioBytes)
      : s = ZcmState(bufBytes),
        _ppmd = ppmdBytes > 0
            ? (PpmdByteModel(spec.ppmdOrder, ppmdBytes)
              ..gate = spec.gainGate ? ZcmGainGate() : null)
            : null,
        _lstm = lstmCells > 0
            ? LstmByteModel(lstmCells, lstmLayers, lstmHorizon)
            : null,
        _orders = OrderModel(spec.orders, bo,
            rich: spec.rich, bh: spec.bh, pairs: spec.bh),
        _match = spec.pxMatch
            ? PxMatchModel(matchEntries * 8, matchEntries * 4,
                mapLBits: zcmHashBitsFor(matchEntries * 4, 42),
                lensText: const [4, 6, 8],
                lensBinary: const [4, 6, 8],
                lensExe: const [3, 5, 8])
            : MatchModel(matchEntries, bufBytes,
                minS: spec.matchMinS,
                minL: spec.matchMinL > 0 ? spec.matchMinL : 1 << 30),
        _word = spec.wordContexts == 0
            ? null
            : (spec.wordContexts > 16
                ? PxWordModel(bw)
                : WordModel(bw, contexts: spec.wordContexts)),
        _sparse = spec.sparse ? SparseModel(bs, light: spec.sparseLight) : null,
        _indirect =
            spec.indirect ? IndirectModel(bi, full: spec.fullIndirect) : null,
        _charGroup = spec.charGroup ? CharGroupModel(bg) : null,
        _dmc = bd > 0
            ? (DmcModel(bd)..gate = spec.gainGate ? ZcmGainGate() : null)
            : null,
        _chart = spec.chart ? ChartModel(bc) : null,
        _nest = spec.nest ? NestModel(bn) : null,
        _xml = spec.xml ? XmlModel(bx) : null,
        _sparseMatch = bsm > 0 ? SparseMatchModel(bsm) : null,
        _sparseBit = bsb > 0 ? SparseBitModel(bsb) : null,
        _lp = spec.linearPrediction ? LinearPredictionModel() : null,
        _sim = bsi > 0 ? SimilarityModel(bsi, spec.similarity) : null,
        _text = bt > 0
            ? TextModel(bt, mixerSets: spec.textSets, contexts: null)
            : null,
        _record = spec.record ? RecordModel(br) : null,
        _exe = spec.exe == 0
            ? null
            : (spec.exe == 1
                ? ExeModel(be, contexts: 5)
                : X86Model(be, full: spec.exe >= 3)),
        _a1 = spec.apms >= 1 && spec.apms <= 4 ? Apm(256 * 8) : null,
        _a2 = spec.apms >= 2 && spec.apms <= 4 ? Apm(65536) : null,
        _a3 = spec.apms >= 3 && spec.apms <= 4 ? Apm(65536) : null,
        _a4 = spec.apms == 4 ? Apm(65536) : null,
        tableBytes = bufBytes +
            matchBytes +
            bo +
            bw +
            bs +
            bi +
            br +
            be +
            bg +
            (bd > 0 ? DmcModel.nodesFor(bd) * 12 : 0) +
            bc +
            bn +
            bx +
            bt +
            (bsm > 0 ? SparseMatchModel.tableBytes(bsm, 17) : 0) +
            bsb +
            bsi +
            ppmdBytes +
            sseBytes;

  /// Bytes the image and audio models add when such data appears.
  int get mediaTableBytes =>
      (_imageBytes > 0 ? ImageModel.tableBytes(_imageBytes) : 0) +
      (_audioBytes > 0 ? AudioModel.tableBytes(_audioBytes) : 0);

  List<ZcmModel> _modelsFor(int type) {
    final l = <ZcmModel>[_orders, _match];
    if (type == ZcmBlockType.audio && _audioBytes > 0) {
      // media agent: audio 3 is paq8px's full predictor set.
      l.add(_audio ??= AudioModel(_audioBytes,
          full: spec.audio >= 2, big: spec.audio >= 3));
      if (_record != null) l.add(_record);
      if (_lstm != null) l.add(_lstm);
      return l;
    }
    // media agent: 1 and 4 bit images (a quarter of the image budget).
    if (ZcmBlockType.isBitImage(type) && _imageBytes > 0) {
      l.add(_bitImage ??= ZcmBitImageModel(_imageBytes ~/ 4));
      return l;
    }
    if (ZcmBlockType.isImage(type) && _imageBytes > 0) {
      l.add(_image ??= ImageModel(_imageBytes, full: spec.image >= 2));
      if (_lstm != null) l.add(_lstm);
      return l;
    }
    final w = _word;
    if (w != null && (type == ZcmBlockType.text || spec.wordAlways)) l.add(w);
    final tm = _text;
    if (tm != null &&
        (type == ZcmBlockType.text ||
            (spec.text >= 2 && type == ZcmBlockType.binary))) {
      l.add(tm);
    }
    if (_sparse != null) l.add(_sparse);
    final isText = type == ZcmBlockType.text;
    final sm = _sparseMatch;
    if (sm != null && (!isText || spec.sparseMatch >= 2)) l.add(sm);
    final sb = _sparseBit;
    if (sb != null && (!isText || spec.sparseBit >= 2)) l.add(sb);
    final lp = _lp;
    if (lp != null && type == ZcmBlockType.binary) l.add(lp);
    final si = _sim;
    if (si != null && !isText) l.add(si);
    if (_indirect != null) l.add(_indirect);
    if (_record != null) l.add(_record);
    final x = _exe;
    if (x != null && type == ZcmBlockType.exe) l.add(x);
    if (_charGroup != null) l.add(_charGroup);
    if (_chart != null) l.add(_chart);
    if (_nest != null && type != ZcmBlockType.exe) l.add(_nest);
    if (_xml != null && type == ZcmBlockType.text) l.add(_xml);
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
    if (sel >= 7) sizes.addAll(const [1024, 256, 1536]);
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
    return Mixer(n, sizes,
        finalContexts: 8,
        initWeight: w0,
        finalRate: spec.finalRate,
        finalRateMin: spec.finalRateMin);
  }

  @override
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
    final c4 = st.c4;
    // Recent mispredictions of the final probability.
    final miss = (_pr >= 2048) != (y == 1) ? 1 : 0;
    _misses = ((_misses << 1) | miss) & 0xFFFF;
    final m3 = (_misses & 1) |
        ((_misses & 0xFE) != 0 ? 2 : 0) |
        ((_misses & 0xFF00) != 0 ? 4 : 0);
    m.set(c0);
    final ml = _match.length;
    final mq = ml == 0
        ? 0
        : (ml < 16 ? 1 + (ml >> 2) : (ml < 32 ? 5 : (ml < 64 ? 6 : 7)));
    final sel = spec.selectors;
    final hits = _orders.hits;
    if (sel >= 2) m.set(mq << 3 | bpos);
    if (sel >= 3) m.set(c4 & 255);
    if (sel >= 4) {
      final h = hits > 15 ? 15 : hits;
      m.set(((h << 2) | (m3 & 3)) << 3 | bpos);
    }
    if (sel >= 5) m.set((c4 >> 8) & 255);
    if (sel >= 6) {
      final low = c0 & ((1 << bpos) - 1);
      final flag = (low == 0 || c0 == (2 << bpos) - 1) ? 1 : 0;
      m.set((c4 & 255) | (bpos > 5 ? 256 : 0) | flag << 9);
    }
    if (sel >= 7) {
      // paq8px NormalModel::mixPost.
      final c1 = c4 & 255, c2 = (c4 >> 8) & 255, c3 = (c4 >> 16) & 255;
      final o = hits > 7 ? 7 : hits;
      final bt = type == ZcmBlockType.binary
          ? 0
          : (type == ZcmBlockType.text
              ? 1
              : (type == ZcmBlockType.exe ? 2 : 3));
      m.set(o |
          (c1 >> 6) << 3 |
          (bpos == 0 ? 32 : 0) |
          (c1 == c2 ? 64 : 0) |
          bt << 7);
      m.set(c3);
      int c;
      if (bpos != 0) {
        c = (c0 << (8 - bpos)) & 255;
        if (bpos == 1) c |= c3 >> 1;
        c = (bpos < 5 ? bpos : 5) << 8 | c1 >> 5 | (c2 >> 5) << 3 | (c & 192);
      } else {
        c = c3 >> 7 | (c4 >> 31) << 1 | (c2 >> 6) << 2 | (c1 & 240);
      }
      m.set(c);
    }
    final extra = _extra[type]!;
    for (var i = 0; i < extra.length; i++) {
      extra[i].setMixerContexts(st, m);
    }
    m.setFinal(bpos);
    final pr = m.p();
    _prMix = pr;
    final img = _image;
    if (spec.apms >= 5 && img != null && ZcmBlockType.isImage(type)) {
      final sse = _sseImage ??= _SsePx(_sseBits);
      final pf = sse.image(y, pr, c0, bpos, m3, img.plane, img.pxW, img.pxN,
          img.pxWW, img.pxNN, img.shapeCtx);
      _pr = pf >> 4;
      return pf;
    }
    if (spec.apms >= 5) {
      final isText = type == ZcmBlockType.text;
      final sse = isText
          ? (_sseText ??= _SsePx(_sseBits, _text != null ? 32768 : 2048))
          : (_sseGeneric ??= _SsePx(_sseBits));
      final e = _match.expectedByte;
      final no = hits > 7 ? 7 : hits;
      final w = _word;
      final wo = w is PxWordModel ? w.order : 0;
      final len2 = ml == 0 ? 0 : (ml < 16 ? 1 : (ml < 32 ? 2 : 3));
      final tm = _text;
      final useTm = tm != null && isText;
      final pf = isText
          ? (useTm
              ? sse.textPx(y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo,
                  tm.mask, tm.firstLetter, tm.order)
              : sse.text(y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo))
          : sse.generic(y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo);
      _pr = pf >> 4;
      return pf;
    }
    var pf = pr << 4;
    final a1 = _a1;
    if (a1 != null) {
      final p1 = a1.pp16(y, pr, c0 | m3 << 8);
      final a2 = _a2;
      if (a2 == null) {
        pf = (pf * 3 + p1 + 2) >> 2;
      } else {
        final p2 = a2.pp16(y, pr, (hash2(c4 & 0xFFFF, c0)) & 0xFFFF);
        final a3 = _a3;
        if (a3 == null) {
          pf = (pf * 2 + p1 + p2 + 2) >> 2;
        } else {
          final p3 = a3.pp16(y, pr, (hash2(c4 & 0xFFFFFF, c0 + 256)) & 0xFFFF);
          final a4 = _a4;
          int pa;
          if (a4 == null) {
            pa = (pf + p2 + p3 * 2 + 2) >> 2;
          } else {
            final e = _match.expectedByte;
            final p4 = a4.pp16(y, pr, e < 0 ? c0 : (hash3(e, mq, c0) & 0xFFFF));
            pa = (pf + p2 + p3 + p4 + 2) >> 2;
          }
          pf = (pa * 3 + p1 + 2) >> 2;
        }
      }
    }
    if (pf < 1) pf = 1;
    if (pf > 65535) pf = 65535;
    _pr = pf >> 4;
    return pf;
  }

  @override
  void setSegment(int type, int info) {
    final st = s;
    st.blockType = type;
    st.blockInfo = info;
    st.blockPos = 0;
  }

  /// The mixer output before the SSE stages (for diagnostics).
  int get mixerOutput => _prMix;

  @override
  @pragma('vm:prefer-inline')
  void update(int bit) => s.update(bit);
}

final Uint8List _charClass = () {
  final t = Uint8List(256);
  for (var c = 0; c < 256; c++) {
    int k;
    if (c >= 0x61 && c <= 0x7A) {
      k = 0;
    } else if (c >= 0x41 && c <= 0x5A) {
      k = 1;
    } else if (c >= 0x30 && c <= 0x39) {
      k = 2;
    } else if (c == 0x20) {
      k = 3;
    } else if (c == 0x0A || c == 0x0D) {
      k = 4;
    } else if (c >= 0x80) {
      k = 7;
    } else if (c < 0x20) {
      k = 6;
    } else {
      k = 5;
    }
    t[c] = k;
  }
  return t;
}();

/// The final probability refinement of paq8px (SSE.cpp, Text and Generic
/// chains): four APMs on the mixer output, three APM1s on their results,
/// and two APMPosts that give the 16 bit probability. The hashed contexts
/// have [bits] bits (16 in paq8px), fewer for small budgets.
final class _SsePx {
  final ApmPx a0, a1, a2, a3;
  final Apm1 b1, b2, b3;
  final ApmPost postA, postB;
  final int mask;
  final int b1Mask; // -1: the whole 256 * 257 contexts

  @pragma('vm:prefer-inline')
  int _b1cx(int cx) => b1Mask < 0 ? cx : hash2(cx, 1) & b1Mask;

  /// Context bits for a budget: both chains take at most a sixth of it.
  static int bitsFor(int budgetBytes) {
    var b = 16;
    while (b > 8 && bytesFor(b) * 12 > budgetBytes) {
      b--;
    }
    return b;
  }

  static int _b1Contexts(int bits) => bits >= 16 ? 256 * 257 : 1 << bits;

  /// Bytes of one chain.
  static int bytesFor(int bits) =>
      (2048 * 24 + 3 * (1 << bits) * 24) * 4 +
      (_b1Contexts(bits) + 2 * (1 << bits)) * 33 * 2 +
      2 * 8 * 4096 * 8;

  _SsePx(int bits, [int a0n = 2048])
      : a0 = ApmPx(a0n, 24),
        a1 = ApmPx(1 << bits, 24),
        a2 = ApmPx(1 << bits, 24),
        a3 = ApmPx(1 << bits, 24),
        b1 = Apm1(_b1Contexts(bits), 7),
        b1Mask = bits >= 16 ? -1 : (1 << bits) - 1,
        b2 = Apm1(1 << bits, 6),
        b3 = Apm1(1 << bits, 6),
        postA = ApmPost(8),
        postB = ApmPost(8),
        mask = (1 << bits) - 1;

  @pragma('vm:prefer-inline')
  static int _avg4(int a, int b, int c, int d) => (a + b + c + d + 2) >> 2;

  // SSE::p, TEXT
  int text(int y, int pr, int c0, int bpos, int c4, int m3, int e, int len2,
      int no, int wo) {
    final cls = _charClass[c4 & 255];
    final p0 = a0.pp(y, pr, (c0 << 3 | cls) & 2047);
    final p1 = a1.pp(y, pr, hash4(bpos, m3 & 3, c4 & 0xFFFF, cls) & mask);
    final p2 = a2.pp(y, pr, hash2(c0, e << 2 | len2) & mask);
    final p3 = a3.pp(y, pr, hash3(c0, c4 & 0xFFFF, wo) & mask);
    final pA = _avg4(pr << 4, p1, p2, p3);
    final p4 = b1.pp(
        y, pA >> 4, _b1cx(e + ((wo >> 2) << 5 | len2 << 3 | (no >> 1)) * 257));
    final p5 = b2.pp(y, p0 >> 4, hash2(c0, c4 & 0xFFFFFF) & mask);
    final p6 = b3.pp(y, p0 >> 4, hash2(c0, c4) & mask);
    final pB = _avg4(p0, p4, p5, p6);
    var p = (postA.pp(y, pA >> 4, bpos) + postB.pp(y, pB >> 4, bpos) + 1) >> 1;
    if (p < 1) p = 1;
    if (p > 65535) p = 65535;
    return p;
  }

  // SSE::p, TEXT with the TextModel's state.
  int textPx(int y, int pr, int c0, int bpos, int c4, int m3, int e, int len2,
      int no, int wo, int tmask, int tfirst, int torder) {
    final p0 = a0.pp(y, pr, (c0 << 7 | (tmask & 0x0F) | m3 << 4) & 0x7FFF);
    final p1 =
        a1.pp(y, pr, hash4(bpos, m3 & 3, c4 & 0xFFFF, tmask >> 4) & mask);
    final p2 = a2.pp(y, pr, hash2(c0, e << 2 | len2) & mask);
    final p3 = a3.pp(y, pr, hash3(c0, c4 & 0xFFFF, tfirst) & mask);
    final pA = _avg4(pr << 4, p1, p2, p3);
    final p4 = b1.pp(y, pA >> 4,
        _b1cx(e + ((wo >> 2) << 5 | len2 << 3 | (torder >> 1)) * 257));
    final p5 = b2.pp(y, p0 >> 4, hash2(c0, c4 & 0xFFFFFF) & mask);
    final p6 = b3.pp(y, p0 >> 4, hash2(c0, c4) & mask);
    final pB = _avg4(p0, p4, p5, p6);
    var p = (postA.pp(y, pA >> 4, bpos) + postB.pp(y, pB >> 4, bpos) + 1) >> 1;
    if (p < 1) p = 1;
    if (p > 65535) p = 65535;
    return p;
  }

  // SSE::p, IMAGE24 (colors) and IMAGE8GRAY in one: the plane, the
  // pixels W, WW, N, NN and the neighborhood shape.
  int image(int y, int pr, int c0, int bpos, int m3, int plane, int w, int n,
      int ww, int nn, int ctx) {
    final pl = plane & 3;
    final p0 = a0.pp(y, pr, pl << 5 | bpos << 2 | (bpos == 0 ? 0 : (m3 & 3)));
    final p1 = a1.pp(y, pr, hash3(c0, w, ww) & mask);
    final p2 = a2.pp(y, pr, hash3(c0, n, nn) & mask);
    final p3 = a3.pp(y, pr, hash2(c0 << 8 | ctx, pl) & mask);
    final pA = _avg4(pr << 4, p1, p2, p3);
    final p4 = b1.pp(y, p0 >> 4, _b1cx((pl << 3 | bpos) + 257 * (ctx & 0xF8)));
    final p5 = b2.pp(y, p0 >> 4, hash3(c0, (w + n) >> 1, pl) & mask);
    final pB = (p0 * 2 + p4 * 3 + p5 * 3 + 4) >> 3;
    var p = (postA.pp(y, pA >> 4, bpos) + postB.pp(y, pB >> 4, bpos) + 1) >> 1;
    if (p < 1) p = 1;
    if (p > 65535) p = 65535;
    return p;
  }

  // SSE::p, DEFAULT
  int generic(int y, int pr, int c0, int bpos, int c4, int m3, int e, int len2,
      int no, int wo) {
    final p0 = a0.pp(y, pr, len2 << 6 | bpos << 3 | m3);
    final p1 = a1.pp(y, pr, (no << 5 | len2 << 3 | bpos) & mask);
    final p2 = a2.pp(y, pr, (c0 | (c4 & 0xFF) << 8) & mask);
    final p3 = a3.pp(y, pr, hash2(c0, c4 & 0xFFFF) & mask);
    final pA = _avg4(pr << 4, p1, p2, p3);
    final p4 = b1.pp(y, pA >> 4, _b1cx(e + (m3 << 5 | no << 2 | len2) * 257));
    final p5 =
        b2.pp(y, p0 >> 4, (m3 << 13 | len2 << 11 | (wo >> 2) << 8 | c0) & mask);
    final p6 = b3.pp(
        y,
        p0 >> 4,
        ((m3 & 3) << 14 | (bpos >> 1) << 12 | (c4 & 0xFF) << 4 | (wo >> 1)) &
            mask);
    final pB = _avg4(p0, p4, p5, p6);
    var p = (postA.pp(y, pA >> 4, no) + postB.pp(y, pB >> 4, len2) + 1) >> 1;
    if (p < 1) p = 1;
    if (p > 65535) p = 65535;
    return p;
  }
}
