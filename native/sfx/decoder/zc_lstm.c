// zxsfx decoder: port of zcm_lstm.dart, the LSTM byte model of level 9.
//
// After the LSTM of cmix (Byron Knoll; lstm-compress and cmix v21:
// mixer/lstm.cpp, mixer/lstm-layer.cpp): stacked LSTM layers whose input
// is the previous byte (one-hot, a weight column per symbol), the
// layer's own last output and the output of the layer below; coupled
// forget and input gates, layer normalisation, truncated back
// propagation through time with Adam, and a softmax output layer.
// With aux = 256 it is cmix's ByteMixer (mixer/byte-mixer.cpp).
//
// Only +, -, *, / and comparisons on doubles, with zexp, ztanh,
// zsigmoid and zsqrt, in the order of the Dart code.

#include "zc_lstm.h"

#define BETA1 0.025
#define BETA2 0.9999
#define EPS 1e-6

static double *dnew(i64 n) { return ZNEW(double, n > 0 ? n : 1); }

static void gate_init(ZLstmGate *g, i64 n, i64 inputs, i64 horizon) {
  g->n = n;
  g->rowLen = 256 + inputs;
  g->wlen = n * (256 + inputs);
  g->w = dnew(g->wlen);
  g->u = dnew(g->wlen);
  g->m = dnew(g->wlen);
  g->v = dnew(g->wlen);
  g->gamma = dnew(n);
  for (i64 i = 0; i < n; i++) g->gamma[i] = 1.0;
  g->beta = dnew(n);
  g->gammaU = dnew(n);
  g->gammaM = dnew(n);
  g->gammaV = dnew(n);
  g->betaU = dnew(n);
  g->betaM = dnew(n);
  g->betaV = dnew(n);
  g->error = dnew(n);
  g->norm = dnew(horizon * n);
  g->ivar = dnew(horizon);
  g->state = dnew(horizon * n);
  g->transpose = dnew(inputs * n);
}

static void layer_init(ZLstmLayer *l, i64 n, i64 inputs, i64 horizon) {
  l->n = n;
  l->inputs = inputs;
  l->horizon = horizon;
  gate_init(&l->forget, n, inputs, horizon);
  gate_init(&l->node, n, inputs, horizon);
  gate_init(&l->output, n, inputs, horizon);
  l->cell = dnew(n);
  l->stateError = dnew(n);
  l->storedError = dnew(n);
  l->tanhState = dnew(horizon * n);
  l->inputGate = dnew(horizon * n);
  l->lastState = dnew(horizon * n);
  l->x = dnew(horizon * inputs);
  l->updateSteps = 0;
}

// Uniform in [0, 1) from a 32-bit LCG (deterministic).
static double lstm_rand(ZcmLstm *l) {
  l->seed = (l->seed * 1103515245 + 12345) & 0x7FFFFFFF;
  return (double)l->seed / 2147483648.0;
}

void zlstm_init(ZcmLstm *l, i64 cells, i64 layers, i64 horizon, i64 aux) {
  l->cells = cells;
  l->layers = layers;
  l->horizon = horizon;
  l->aux = aux;
  l->learningRate = 0.03;
  l->gradientClip = 10.0;
  l->hl = layers * cells + 1;
  l->hidden = dnew(l->hl);
  l->hiddenError = dnew(cells);
  l->wOut = dnew(256 * l->hl);
  l->out = dnew(horizon * 256);
  for (i64 i = 0; i < horizon * 256; i++) l->out[i] = 1.0 / 256.0;
  l->inputHist = ZNEW(i32, horizon);
  l->auxv = dnew(aux);
  l->beta1Pow = dnew(3001);
  l->beta2Pow = dnew(3001);
  l->epoch = 0;
  l->updateLimit = 3000;
  l->seed = 0x12345678;
  l->lay = ZNEW(ZLstmLayer, layers);
  l->hidden[l->hl - 1] = 1.0;
  for (i64 li = 0; li < layers; li++) {
    i64 inputs = cells + (li > 0 ? cells : 0) + aux + 1;
    ZLstmLayer *layer = &l->lay[li];
    layer_init(layer, cells, inputs, horizon);
    // Bias input of every step.
    for (i64 e = 0; e < horizon; e++) {
      layer->x[e * inputs + inputs - 1] = 1.0;
    }
    double val = zsqrt(6.0 / 512.0);
    ZLstmGate *gs[3] = {&layer->forget, &layer->node, &layer->output};
    for (int k = 0; k < 3; k++) {
      ZLstmGate *g = gs[k];
      for (i64 i = 0; i < g->wlen; i++) {
        double r = lstm_rand(l);
        g->w[i] = -val + r * 2.0 * val;
      }
    }
    for (i64 i = 0; i < cells; i++) {
      layer->forget.w[i * layer->forget.rowLen + layer->forget.rowLen - 1] =
          1.0;
    }
  }
  double b1 = 1.0, b2 = 1.0;
  for (i64 t = 0; t <= 3000; t++) {
    l->beta1Pow[t] = b1;
    l->beta2Pow[t] = b2;
    b1 *= BETA1;
    b2 *= BETA2;
  }
}

void zlstm_setAux(ZcmLstm *l, const double *v) {
  for (i64 i = 0; i < l->aux; i++) l->auxv[i] = v[i];
}

const double *zlstm_probabilities(const ZcmLstm *l) {
  i64 last = l->epoch == 0 ? l->horizon - 1 : l->epoch - 1;
  return l->out + last * 256;
}

// LstmLayer::ForwardPass (NeuronLayer)
static void gate_forward(ZcmLstm *l, ZLstmLayer *layer, ZLstmGate *g, i64 e,
                         i64 symbol) {
  i64 n = l->cells;
  i64 ni = layer->inputs;
  const double *x = layer->x;
  i64 xb = e * ni;
  const double *w = g->w;
  i64 rl = g->rowLen;
  i64 nb = e * n;
  double sq = 0.0;
  for (i64 i = 0; i < n; i++) {
    i64 wb = i * rl;
    double f = w[wb + symbol];
    i64 wi = wb + 256;
    for (i64 j = 0; j < ni; j++) {
      f += x[xb + j] * w[wi + j];
    }
    g->norm[nb + i] = f;
    sq += f * f;
  }
  double iv = 1.0 / zsqrt(sq / (double)n + 1e-5);
  g->ivar[e] = iv;
  for (i64 i = 0; i < n; i++) {
    double v = g->norm[nb + i] * iv;
    g->norm[nb + i] = v;
    g->state[nb + i] = v * g->gamma[i] + g->beta[i];
  }
}

// LstmLayer::ForwardPass
static void layer_forward(ZcmLstm *l, ZLstmLayer *layer, i64 e, i64 symbol) {
  i64 n = l->cells;
  i64 sb = e * n;
  for (i64 i = 0; i < n; i++) layer->lastState[sb + i] = layer->cell[i];
  gate_forward(l, layer, &layer->forget, e, symbol);
  gate_forward(l, layer, &layer->node, e, symbol);
  gate_forward(l, layer, &layer->output, e, symbol);
  double *f = layer->forget.state;
  double *nd = layer->node.state;
  double *o = layer->output.state;
  for (i64 i = 0; i < n; i++) {
    f[sb + i] = zsigmoid(f[sb + i]);
    nd[sb + i] = ztanh(nd[sb + i]);
    o[sb + i] = zsigmoid(o[sb + i]);
    double ig = 1.0 - f[sb + i];
    layer->inputGate[sb + i] = ig;
    double c = layer->cell[i] * f[sb + i] + nd[sb + i] * ig;
    layer->cell[i] = c;
    layer->tanhState[sb + i] = ztanh(c);
  }
}

static void adam(ZcmLstm *l, double *gr, double *m, double *v, double *w,
                 i64 len, i64 t) {
  i64 tt = t < l->updateLimit ? t : l->updateLimit;
  double alpha = l->learningRate * 0.1 / zsqrt(5e-5 * (double)tt + 1.0);
  double c1 = 1.0 / (1.0 - l->beta1Pow[tt]);
  double c2 = 1.0 / (1.0 - l->beta2Pow[tt]);
  const double b1 = BETA1, b2 = BETA2;
  for (i64 i = 0; i < len; i++) {
    double g = gr[i];
    if (g == 0.0 && m[i] == 0.0) continue;
    double mi = m[i] * b1 + (1.0 - b1) * g;
    double vi = v[i] * b2 + (1.0 - b2) * g * g;
    m[i] = mi;
    v[i] = vi;
    w[i] -= alpha * (mi * c1) / zsqrt(vi * c2 + EPS);
  }
}

// LstmLayer::BackwardPass (NeuronLayer)
static void gate_backward(ZcmLstm *l, ZLstmLayer *layer, ZLstmGate *g, i64 e,
                          i64 li, i64 symbol, double *he) {
  i64 n = l->cells;
  i64 ni = layer->inputs;
  i64 rl = g->rowLen;
  double *tr = g->transpose;
  if (e == l->horizon - 1) {
    for (i64 i = 0; i < n; i++) {
      g->gammaU[i] = 0.0;
      g->betaU[i] = 0.0;
    }
    for (i64 i = 0; i < g->wlen; i++) g->u[i] = 0.0;
    for (i64 i = 0; i < n; i++) {
      i64 wb = i * rl + 256;
      for (i64 j = 0; j < ni; j++) {
        tr[j * n + i] = g->w[wb + j];
      }
    }
  }
  i64 nb = e * n;
  double *err = g->error;
  double dot = 0.0;
  for (i64 i = 0; i < n; i++) {
    g->betaU[i] += err[i];
    g->gammaU[i] += err[i] * g->norm[nb + i];
    err[i] *= g->gamma[i] * g->ivar[e];
    dot += err[i] * g->norm[nb + i];
  }
  double mean = dot / (double)n;
  for (i64 i = 0; i < n; i++) {
    err[i] -= mean * g->norm[nb + i];
  }
  if (li > 0) {
    // Error of the layer below (its output is input cells..2 cells-1).
    for (i64 i = 0; i < n; i++) {
      double f = 0.0;
      i64 tb = (n + i) * n;
      for (i64 j = 0; j < n; j++) {
        f += err[j] * tr[tb + j];
      }
      he[i] += f;
    }
  }
  if (e > 0) {
    double *stored = layer->storedError;
    for (i64 i = 0; i < n; i++) {
      double f = 0.0;
      i64 tb = i * n;
      for (i64 j = 0; j < n; j++) {
        f += err[j] * tr[tb + j];
      }
      stored[i] += f;
    }
  }
  const double *x = layer->x;
  i64 xb = e * ni;
  double *u = g->u;
  for (i64 i = 0; i < n; i++) {
    double ei = err[i];
    i64 ub = i * rl;
    for (i64 j = 0; j < ni; j++) {
      u[ub + 256 + j] += ei * x[xb + j];
    }
    u[ub + symbol] += ei;
  }
  if (e == 0) {
    i64 t = layer->updateSteps;
    adam(l, g->u, g->m, g->v, g->w, g->wlen, t);
    adam(l, g->gammaU, g->gammaM, g->gammaV, g->gamma, n, t);
    adam(l, g->betaU, g->betaM, g->betaV, g->beta, n, t);
  }
}

// LstmLayer::BackwardPass
static void layer_backward(ZcmLstm *l, ZLstmLayer *layer, i64 e, i64 li,
                           i64 symbol, double *he) {
  i64 n = l->cells;
  i64 sb = e * n;
  double *stored = layer->storedError;
  double *se = layer->stateError;
  if (e == l->horizon - 1) {
    for (i64 i = 0; i < n; i++) {
      stored[i] = he[i];
      se[i] = 0.0;
    }
  } else {
    for (i64 i = 0; i < n; i++) stored[i] += he[i];
  }
  const double *f = layer->forget.state;
  const double *nd = layer->node.state;
  const double *o = layer->output.state;
  const double *ts = layer->tanhState;
  const double *ig = layer->inputGate;
  for (i64 i = 0; i < n; i++) {
    double oi = o[sb + i];
    double ti = ts[sb + i];
    layer->output.error[i] = ti * stored[i] * oi * (1.0 - oi);
    se[i] += stored[i] * oi * (1.0 - ti * ti);
    double ni = nd[sb + i];
    layer->node.error[i] = se[i] * ig[sb + i] * (1.0 - ni * ni);
    layer->forget.error[i] =
        (layer->lastState[sb + i] - ni) * se[i] * f[sb + i] * ig[sb + i];
    he[i] = 0.0;
  }
  if (e > 0) {
    for (i64 i = 0; i < n; i++) {
      se[i] *= f[sb + i];
      stored[i] = 0.0;
    }
  } else if (layer->updateSteps < l->updateLimit) {
    layer->updateSteps++;
  }
  gate_backward(l, layer, &layer->forget, e, li, symbol, he);
  gate_backward(l, layer, &layer->node, e, li, symbol, he);
  gate_backward(l, layer, &layer->output, e, li, symbol, he);
  double c = l->gradientClip;
  for (i64 i = 0; i < n; i++) {
    if (se[i] < -c) se[i] = -c;
    if (se[i] > c) se[i] = c;
    if (stored[i] < -c) stored[i] = -c;
    if (stored[i] > c) stored[i] = c;
    if (he[i] < -c) he[i] = -c;
    if (he[i] > c) he[i] = c;
  }
}

static void lstm_predict(ZcmLstm *l, i64 symbol) {
  i64 e = l->epoch;
  i64 cells = l->cells;
  double *hidden = l->hidden;
  for (i64 li = 0; li < l->layers; li++) {
    ZLstmLayer *layer = &l->lay[li];
    i64 ni = layer->inputs;
    i64 xb = e * ni;
    double *x = layer->x;
    // Inputs: own last output, the output of the layer below, bias.
    for (i64 j = 0; j < cells; j++) x[xb + j] = hidden[li * cells + j];
    i64 ab = xb + cells;
    if (li > 0) {
      for (i64 j = 0; j < cells; j++) {
        x[xb + cells + j] = hidden[(li - 1) * cells + j];
      }
      ab += cells;
    }
    // The dense inputs (byte mixer), after the hidden states.
    for (i64 j = 0; j < l->aux; j++) x[ab + j] = l->auxv[j];
    layer_forward(l, layer, e, symbol);
    // The new output of the layer.
    i64 sb = e * cells;
    for (i64 i = 0; i < cells; i++) {
      hidden[li * cells + i] =
          layer->output.state[sb + i] * layer->tanhState[sb + i];
    }
  }
  // Softmax output.
  i64 hl = l->hl;
  i64 ob = e * 256;
  double *out = l->out;
  double maxOut = 0.0;
  for (i64 k = 0; k < 256; k++) {
    double s = 0.0;
    i64 wb = k * hl;
    for (i64 j = 0; j < hl; j++) s += hidden[j] * l->wOut[wb + j];
    out[ob + k] = s;
    if (s > maxOut) maxOut = s;
  }
  double sum = 0.0;
  for (i64 k = 0; k < 256; k++) {
    double v = zexp(out[ob + k] - maxOut);
    out[ob + k] = v;
    sum += v;
  }
  double inv = 1.0 / sum;
  for (i64 k = 0; k < 256; k++) out[ob + k] *= inv;
  l->epoch++;
  if (l->epoch == l->horizon) l->epoch = 0;
}

void zlstm_perceive(ZcmLstm *l, i64 symbol) {
  i64 horizon = l->horizon;
  i64 last = l->epoch == 0 ? horizon - 1 : l->epoch - 1;
  i64 oldInput = l->inputHist[last];
  l->inputHist[last] = (i32)symbol;
  i64 hl = l->hl;
  i64 cells = l->cells;
  const double *out = l->out;
  if (l->epoch == 0) {
    // Back propagation through the whole horizon.
    double *he = l->hiddenError;
    for (i64 e = horizon - 1; e >= 0; e--) {
      for (i64 li = l->layers - 1; li >= 0; li--) {
        i64 off = li * cells;
        i64 target = l->inputHist[e];
        i64 ob = e * 256;
        for (i64 k = 0; k < 256; k++) {
          double err = k == target ? out[ob + k] - 1.0 : out[ob + k];
          if (err == 0.0) continue;
          i64 wb = k * hl + off;
          for (i64 j = 0; j < cells; j++) he[j] += l->wOut[wb + j] * err;
        }
        i64 prev = e == 0 ? horizon - 1 : e - 1;
        i64 sym = e == 0 ? oldInput : l->inputHist[prev];
        layer_backward(l, &l->lay[li], e, li, sym, he);
      }
    }
  }
  // Output layer, plain gradient descent.
  i64 ob = last * 256;
  double lr = l->learningRate;
  for (i64 k = 0; k < 256; k++) {
    double err = k == symbol ? out[ob + k] - 1.0 : out[ob + k];
    double g = lr * err;
    i64 wb = k * hl;
    for (i64 j = 0; j < hl; j++) l->wOut[wb + j] -= g * l->hidden[j];
  }
  lstm_predict(l, symbol);
}
