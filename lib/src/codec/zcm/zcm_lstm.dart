// zcm: LSTM byte model (level 9).
//
// After the LSTM of cmix (Byron Knoll; lstm-compress and cmix v21:
// mixer/lstm.cpp, mixer/lstm-layer.cpp): stacked LSTM layers whose input
// is the previous byte (one-hot, a weight column per symbol), the
// layer's own last output and the output of the layer below; the forget
// and input gates are coupled (input = 1 - forget), each gate has layer
// normalisation, truncated back propagation through time every [horizon]
// bytes trains the gates with Adam and the softmax output layer learns
// every byte. The output is a probability for each of the 256 next
// bytes.
//
// With [ZcmLstm.aux] = 256 it is cmix's ByteMixer (mixer/byte-mixer.cpp):
// the byte distributions of the other byte models are dense inputs of
// every layer beside the previous byte.
//
// Differences from cmix: doubles instead of floats; the output
// layer is shared across the horizon (cmix keeps a copy per step); the
// weights are initialised from a fixed seed.
//
// Determinism: only +, -, *, / and comparisons on doubles, with the exp,
// tanh, logistic and sqrt of zcm_math.dart, in a fixed order, so the
// predictions are bit for bit the same on every platform.

import 'dart:typed_data';

import 'zcm_math.dart';

final class _Gate {
  final int n; // cells
  final int rowLen; // 256 symbol columns + inputs
  final Float64List w;
  final Float64List u; // accumulated gradient
  final Float64List m;
  final Float64List v;
  final Float64List gamma;
  final Float64List beta;
  final Float64List gammaU, gammaM, gammaV;
  final Float64List betaU, betaM, betaV;
  final Float64List error;
  final Float64List norm; // horizon * n
  final Float64List ivar; // horizon
  final Float64List state; // horizon * n (after the nonlinearity)
  final Float64List transpose; // (inputs) * n

  _Gate(this.n, int inputs, int horizon)
      : rowLen = 256 + inputs,
        w = Float64List(n * (256 + inputs)),
        u = Float64List(n * (256 + inputs)),
        m = Float64List(n * (256 + inputs)),
        v = Float64List(n * (256 + inputs)),
        gamma = Float64List(n)..fillRange(0, n, 1.0),
        beta = Float64List(n),
        gammaU = Float64List(n),
        gammaM = Float64List(n),
        gammaV = Float64List(n),
        betaU = Float64List(n),
        betaM = Float64List(n),
        betaV = Float64List(n),
        error = Float64List(n),
        norm = Float64List(horizon * n),
        ivar = Float64List(horizon),
        state = Float64List(horizon * n),
        transpose = Float64List(inputs * n);
}

final class _Layer {
  final int n;
  final int inputs; // own hidden + lower hidden + bias
  final int horizon;
  final _Gate forget, node, output;
  final Float64List cell;
  final Float64List stateError;
  final Float64List storedError;
  final Float64List tanhState; // horizon * n
  final Float64List inputGate; // horizon * n
  final Float64List lastState; // horizon * n
  final Float64List x; // horizon * inputs: the inputs of each step
  int updateSteps = 0;

  _Layer(this.n, this.inputs, this.horizon)
      : forget = _Gate(n, inputs, horizon),
        node = _Gate(n, inputs, horizon),
        output = _Gate(n, inputs, horizon),
        cell = Float64List(n),
        stateError = Float64List(n),
        storedError = Float64List(n),
        tanhState = Float64List(horizon * n),
        inputGate = Float64List(horizon * n),
        lastState = Float64List(horizon * n),
        x = Float64List(horizon * inputs);
}

/// A deterministic LSTM predicting the next byte.
final class ZcmLstm {
  final int cells;
  final int layers;
  final int horizon;

  /// Dense inputs besides the previous byte (0, or 256 for the byte
  /// mixer: the byte distributions of other models, as cmix's ByteMixer
  /// feeds its LSTM), given by [setAux] before each [perceive].
  final int aux;
  final Float64List _aux;
  final double learningRate;
  final double gradientClip;
  final List<_Layer> _layers = [];
  final Float64List hidden; // layers * cells + 1 (bias)
  final Float64List _hiddenError;
  final Float64List _wOut; // 256 * hidden.length
  final Float64List _out; // horizon * 256
  final Int32List _inputHist;
  int _epoch = 0;
  final int _updateLimit = 3000;
  // Powers of the Adam betas for the bias correction.
  final Float64List _beta1Pow;
  final Float64List _beta2Pow;
  int _seed = 0x12345678;

  static const double _beta1 = 0.025;
  static const double _beta2 = 0.9999;
  static const double _eps = 1e-6;

  ZcmLstm(
      {this.cells = 64,
      this.layers = 1,
      this.horizon = 20,
      this.aux = 0,
      this.learningRate = 0.03,
      this.gradientClip = 10.0})
      : hidden = Float64List(layers * cells + 1),
        _hiddenError = Float64List(cells),
        _wOut = Float64List(256 * (layers * cells + 1)),
        _out = Float64List(horizon * 256)..fillRange(0, horizon * 256, 1 / 256),
        _inputHist = Int32List(horizon),
        _aux = Float64List(aux),
        _beta1Pow = Float64List(3001),
        _beta2Pow = Float64List(3001) {
    hidden[hidden.length - 1] = 1.0;
    for (var l = 0; l < layers; l++) {
      final inputs = cells + (l > 0 ? cells : 0) + aux + 1;
      final layer = _Layer(cells, inputs, horizon);
      _layers.add(layer);
      // Bias input of every step.
      for (var e = 0; e < horizon; e++) {
        layer.x[e * inputs + inputs - 1] = 1.0;
      }
      final val = zsqrt(6.0 / 512.0);
      for (final g in [layer.forget, layer.node, layer.output]) {
        for (var i = 0; i < g.w.length; i++) {
          g.w[i] = -val + _rand() * 2 * val;
        }
      }
      for (var i = 0; i < cells; i++) {
        layer.forget.w[i * layer.forget.rowLen + layer.forget.rowLen - 1] = 1.0;
      }
    }
    var b1 = 1.0, b2 = 1.0;
    for (var t = 0; t <= 3000; t++) {
      _beta1Pow[t] = b1;
      _beta2Pow[t] = b2;
      b1 *= _beta1;
      b2 *= _beta2;
    }
  }

  // Uniform in [0, 1) from a 32-bit LCG (deterministic).
  double _rand() {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed / 2147483648.0;
  }

  /// Sets the dense inputs of the next prediction ([aux] values).
  void setAux(Float64List v) {
    for (var i = 0; i < aux; i++) {
      _aux[i] = v[i];
    }
  }

  /// Probabilities of the next byte after the last [predict].
  Float64List get probabilities {
    final last = _epoch == 0 ? horizon - 1 : _epoch - 1;
    return Float64List.sublistView(_out, last * 256, last * 256 + 256);
  }

  /// Learns that the byte after the last prediction was [symbol], then
  /// predicts the byte after it.
  void perceive(int symbol) {
    final last = _epoch == 0 ? horizon - 1 : _epoch - 1;
    final oldInput = _inputHist[last];
    _inputHist[last] = symbol;
    final hl = hidden.length;
    if (_epoch == 0) {
      // Back propagation through the whole horizon.
      final he = _hiddenError;
      for (var e = horizon - 1; e >= 0; e--) {
        for (var l = layers - 1; l >= 0; l--) {
          final off = l * cells;
          final target = _inputHist[e];
          final ob = e * 256;
          for (var k = 0; k < 256; k++) {
            final err = k == target ? _out[ob + k] - 1.0 : _out[ob + k];
            if (err == 0.0) continue;
            final wb = k * hl + off;
            for (var j = 0; j < cells; j++) {
              he[j] += _wOut[wb + j] * err;
            }
          }
          final prev = e == 0 ? horizon - 1 : e - 1;
          final sym = e == 0 ? oldInput : _inputHist[prev];
          _backward(_layers[l], e, l, sym, he);
        }
      }
    }
    // Output layer, plain gradient descent.
    final ob = last * 256;
    final lr = learningRate;
    for (var k = 0; k < 256; k++) {
      final err = k == symbol ? _out[ob + k] - 1.0 : _out[ob + k];
      final g = lr * err;
      final wb = k * hl;
      for (var j = 0; j < hl; j++) {
        _wOut[wb + j] -= g * hidden[j];
      }
    }
    _predict(symbol);
  }

  void _predict(int symbol) {
    final e = _epoch;
    for (var l = 0; l < layers; l++) {
      final layer = _layers[l];
      final ni = layer.inputs;
      final xb = e * ni;
      final x = layer.x;
      // Inputs: own last output, the output of the layer below, bias.
      for (var j = 0; j < cells; j++) {
        x[xb + j] = hidden[l * cells + j];
      }
      var ab = xb + cells;
      if (l > 0) {
        for (var j = 0; j < cells; j++) {
          x[xb + cells + j] = hidden[(l - 1) * cells + j];
        }
        ab += cells;
      }
      // The dense inputs (byte mixer), after the hidden states.
      for (var j = 0; j < aux; j++) {
        x[ab + j] = _aux[j];
      }
      _forward(layer, e, symbol);
      // The new output of the layer.
      final sb = e * cells;
      for (var i = 0; i < cells; i++) {
        hidden[l * cells + i] =
            layer.output.state[sb + i] * layer.tanhState[sb + i];
      }
    }
    // Softmax output.
    final hl = hidden.length;
    final ob = e * 256;
    var maxOut = 0.0;
    for (var k = 0; k < 256; k++) {
      var s = 0.0;
      final wb = k * hl;
      for (var j = 0; j < hl; j++) {
        s += hidden[j] * _wOut[wb + j];
      }
      _out[ob + k] = s;
      if (s > maxOut) maxOut = s;
    }
    var sum = 0.0;
    for (var k = 0; k < 256; k++) {
      final v = zexp(_out[ob + k] - maxOut);
      _out[ob + k] = v;
      sum += v;
    }
    final inv = 1.0 / sum;
    for (var k = 0; k < 256; k++) {
      _out[ob + k] *= inv;
    }
    _epoch++;
    if (_epoch == horizon) _epoch = 0;
  }

  // LstmLayer::ForwardPass
  void _forward(_Layer layer, int e, int symbol) {
    final n = cells;
    final sb = e * n;
    for (var i = 0; i < n; i++) {
      layer.lastState[sb + i] = layer.cell[i];
    }
    _gateForward(layer, layer.forget, e, symbol);
    _gateForward(layer, layer.node, e, symbol);
    _gateForward(layer, layer.output, e, symbol);
    final f = layer.forget.state;
    final nd = layer.node.state;
    final o = layer.output.state;
    for (var i = 0; i < n; i++) {
      f[sb + i] = zsigmoid(f[sb + i]);
      nd[sb + i] = ztanh(nd[sb + i]);
      o[sb + i] = zsigmoid(o[sb + i]);
      final ig = 1.0 - f[sb + i];
      layer.inputGate[sb + i] = ig;
      final c = layer.cell[i] * f[sb + i] + nd[sb + i] * ig;
      layer.cell[i] = c;
      layer.tanhState[sb + i] = ztanh(c);
    }
  }

  // LstmLayer::ForwardPass (NeuronLayer)
  void _gateForward(_Layer layer, _Gate g, int e, int symbol) {
    final n = cells;
    final ni = layer.inputs;
    final x = layer.x;
    final xb = e * ni;
    final w = g.w;
    final rl = g.rowLen;
    final nb = e * n;
    var sq = 0.0;
    for (var i = 0; i < n; i++) {
      final wb = i * rl;
      var f = w[wb + symbol];
      final wi = wb + 256;
      for (var j = 0; j < ni; j++) {
        f += x[xb + j] * w[wi + j];
      }
      g.norm[nb + i] = f;
      sq += f * f;
    }
    final iv = 1.0 / zsqrt(sq / n + 1e-5);
    g.ivar[e] = iv;
    for (var i = 0; i < n; i++) {
      final v = g.norm[nb + i] * iv;
      g.norm[nb + i] = v;
      g.state[nb + i] = v * g.gamma[i] + g.beta[i];
    }
  }

  // LstmLayer::BackwardPass
  void _backward(_Layer layer, int e, int l, int symbol, Float64List he) {
    final n = cells;
    final sb = e * n;
    final stored = layer.storedError;
    final se = layer.stateError;
    if (e == horizon - 1) {
      for (var i = 0; i < n; i++) {
        stored[i] = he[i];
        se[i] = 0.0;
      }
    } else {
      for (var i = 0; i < n; i++) {
        stored[i] += he[i];
      }
    }
    final f = layer.forget.state;
    final nd = layer.node.state;
    final o = layer.output.state;
    final ts = layer.tanhState;
    final ig = layer.inputGate;
    for (var i = 0; i < n; i++) {
      final oi = o[sb + i];
      final ti = ts[sb + i];
      layer.output.error[i] = ti * stored[i] * oi * (1.0 - oi);
      se[i] += stored[i] * oi * (1.0 - ti * ti);
      final ni = nd[sb + i];
      layer.node.error[i] = se[i] * ig[sb + i] * (1.0 - ni * ni);
      layer.forget.error[i] =
          (layer.lastState[sb + i] - ni) * se[i] * f[sb + i] * ig[sb + i];
      he[i] = 0.0;
    }
    if (e > 0) {
      for (var i = 0; i < n; i++) {
        se[i] *= f[sb + i];
        stored[i] = 0.0;
      }
    } else if (layer.updateSteps < _updateLimit) {
      layer.updateSteps++;
    }
    _gateBackward(layer, layer.forget, e, l, symbol, he);
    _gateBackward(layer, layer.node, e, l, symbol, he);
    _gateBackward(layer, layer.output, e, l, symbol, he);
    final c = gradientClip;
    for (var i = 0; i < n; i++) {
      if (se[i] < -c) se[i] = -c;
      if (se[i] > c) se[i] = c;
      if (stored[i] < -c) stored[i] = -c;
      if (stored[i] > c) stored[i] = c;
      if (he[i] < -c) he[i] = -c;
      if (he[i] > c) he[i] = c;
    }
  }

  // LstmLayer::BackwardPass (NeuronLayer)
  void _gateBackward(
      _Layer layer, _Gate g, int e, int l, int symbol, Float64List he) {
    final n = cells;
    final ni = layer.inputs;
    final rl = g.rowLen;
    final tr = g.transpose;
    if (e == horizon - 1) {
      for (var i = 0; i < n; i++) {
        g.gammaU[i] = 0.0;
        g.betaU[i] = 0.0;
      }
      g.u.fillRange(0, g.u.length, 0.0);
      for (var i = 0; i < n; i++) {
        final wb = i * rl + 256;
        for (var j = 0; j < ni; j++) {
          tr[j * n + i] = g.w[wb + j];
        }
      }
    }
    final nb = e * n;
    final err = g.error;
    var dot = 0.0;
    for (var i = 0; i < n; i++) {
      g.betaU[i] += err[i];
      g.gammaU[i] += err[i] * g.norm[nb + i];
      err[i] *= g.gamma[i] * g.ivar[e];
      dot += err[i] * g.norm[nb + i];
    }
    final mean = dot / n;
    for (var i = 0; i < n; i++) {
      err[i] -= mean * g.norm[nb + i];
    }
    if (l > 0) {
      // Error of the layer below (its output is input cells..2 cells-1).
      for (var i = 0; i < n; i++) {
        var f = 0.0;
        final tb = (n + i) * n;
        for (var j = 0; j < n; j++) {
          f += err[j] * tr[tb + j];
        }
        he[i] += f;
      }
    }
    if (e > 0) {
      final stored = layer.storedError;
      for (var i = 0; i < n; i++) {
        var f = 0.0;
        final tb = i * n;
        for (var j = 0; j < n; j++) {
          f += err[j] * tr[tb + j];
        }
        stored[i] += f;
      }
    }
    final x = layer.x;
    final xb = e * ni;
    final u = g.u;
    for (var i = 0; i < n; i++) {
      final ei = err[i];
      final ub = i * rl;
      for (var j = 0; j < ni; j++) {
        u[ub + 256 + j] += ei * x[xb + j];
      }
      u[ub + symbol] += ei;
    }
    if (e == 0) {
      final t = layer.updateSteps;
      _adam(g.u, g.m, g.v, g.w, t);
      _adam(g.gammaU, g.gammaM, g.gammaV, g.gamma, t);
      _adam(g.betaU, g.betaM, g.betaV, g.beta, t);
    }
  }

  void _adam(Float64List gr, Float64List m, Float64List v, Float64List w,
      int t) {
    final tt = t < _updateLimit ? t : _updateLimit;
    final alpha = learningRate * 0.1 / zsqrt(5e-5 * tt + 1.0);
    final c1 = 1.0 / (1.0 - _beta1Pow[tt]);
    final c2 = 1.0 / (1.0 - _beta2Pow[tt]);
    const b1 = _beta1, b2 = _beta2;
    for (var i = 0; i < w.length; i++) {
      final g = gr[i];
      if (g == 0.0 && m[i] == 0.0) continue;
      final mi = m[i] * b1 + (1.0 - b1) * g;
      final vi = v[i] * b2 + (1.0 - b2) * g * g;
      m[i] = mi;
      v[i] = vi;
      w[i] -= alpha * (mi * c1) / zsqrt(vi * c2 + _eps);
    }
  }
}
