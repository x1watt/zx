// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'compressor.dart';
import 'io.dart';
import 'lzbuffer.dart';
import 'sha1.dart';

bool _isDigit(int c) => c >= 48 && c <= 57;

int _nbits(int x) {
  var r = 0;
  for (; x != 0; x >>= 1) {
    r += x & 1;
  }
  return r;
}

const String _e8e9Decode = '''
    b=0 d=r 4 do (for b=0..d-1, d = end of buf)
      a=b a==d ifnot
        a+= 4 a<d if
          a=*b a&= 254 a== 232 if (e8 or e9?)
            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if (00 or ff)
              b-- a=*b
              b-- a<<= 8 a+=*b
              b-- a<<= 8 a+=*b
              a-=b a++
              *b=a a>>= 8 b++
              *b=a a>>= 8 b++
              *b=a b++
            endif
            b=c
          endif
        endif
        a=*b out b++
      forever
    endif

''';

const String _e8e9Decode2 = '''
    d=b b=0 do (for b=0..d-1, d = end of buf)
      a=b a==d ifnot
        a+= 4 a<d if
          a=*b a&= 254 a== 232 if (e8 or e9?)
            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if (00 or ff)
              b-- a=*b
              b-- a<<= 8 a+=*b
              b-- a<<= 8 a+=*b
              a-=b a++
              *b=a a>>= 8 b++
              *b=a a>>= 8 b++
              *b=a b++
            endif
            b=c
          endif
        endif
        a=*b out b++
      forever
    endif
''';

/// Generates a ZPAQL config from a method string with syntax
/// {0|x|i}[N1[,N2]...][{ciamtswf}[N1[,N2]]...]... and fills [args].
String makeConfig(String method, List<int> args) {
  final type = method.codeUnitAt(0);
  for (var i = 0; i < 9; ++i) {
    args[i] = 0;
  }
  var mp = 1;
  int ch(int i) => i < method.length ? method.codeUnitAt(i) : 0;
  for (var i = 0;
      i < 9 && (_isDigit(ch(mp)) || ch(mp) == 44 || ch(mp) == 46);) {
    if (_isDigit(ch(mp))) {
      args[i] = args[i] * 10 + ch(mp) - 48;
    } else if (++i < 9) {
      args[i] = 0;
    }
    ++mp;
  }

  if (type == 48) return 'comp 0 0 0 0 0 hcomp end\n'; // '0'

  var hdr = '';
  var pcomp = '';
  final level = args[1] & 3;
  final doe8 = args[1] >= 4 && args[1] <= 7;

  if (level == 1) {
    final rb = args[0] > 4 ? args[0] - 4 : 0;
    hdr = r'comp 9 16 0 $1+20 ';
    pcomp = '''
pcomp lazy2 3 ;
 (r1 = state
  r2 = len - match or literal length
  r3 = m - number of offset bits expected
  r4 = ptr to buf
  r5 = r - low bits of offset
  c = bits - input buffer
  d = n - number of bits in c)

  a> 255 if
''';
    if (doe8) pcomp += _e8e9Decode;
    pcomp += '''
    (reset state)
    a=0 b=0 c=0 d=0 r=a 1 r=a 2 r=a 3 r=a 4
    halt
  endif

  a<<=d a+=c c=a               (bits+=a<<n)
  a= 8 a+=d d=a                (n+=8)

  (if state==0 (expect new code))
  a=r 1 a== 0 if (match code mm,mmm)
    a= 1 r=a 2                 (len=1)
    a=c a&= 3 a> 0 if          (if (bits&3))
      a-- a<<= 3 r=a 3           (m=((bits&3)-1)*8)
      a=c a>>= 2 c=a             (bits>>=2)
      b=r 3 a&= 7 a+=b r=a 3     (m+=bits&7)
      a=c a>>= 3 c=a             (bits>>=3)
      a=d a-= 5 d=a              (n-=5)
      a= 1 r=a 1                 (state=1)
    else (literal, discard 00)
      a=c a>>= 2 c=a             (bits>>=2)
      d-- d--                    (n-=2)
      a= 3 r=a 1                 (state=3)
    endif
  endif

  (while state==1 && n>=3 (expect match length n*4+ll into r2))
  do a=r 1 a== 1 if a=d a> 2 if
    a=c a&= 1 a== 1 if         (if bits&1)
      a=c a>>= 1 c=a             (bits>>=1)
      b=r 2 a=c a&= 1 a+=b a+=b r=a 2 (len+=len+(bits&1))
      a=c a>>= 1 c=a             (bits>>=1)
      d-- d--                    (n-=2)
    else
      a=c a>>= 1 c=a             (bits>>=1)
      a=r 2 a<<= 2 b=a           (len<<=2)
      a=c a&= 3 a+=b r=a 2       (len+=bits&3)
      a=c a>>= 2 c=a             (bits>>=2)
      d-- d-- d--                (n-=3)
''';
    if (rb != 0) {
      pcomp += '      a= 5 r=a 1                 (state=5)\n';
    } else {
      pcomp += '      a= 2 r=a 1                 (state=2)\n';
    }
    pcomp += '''
    endif
  forever endif endif

''';
    if (rb != 0) {
      pcomp +=
          '  (if state==5 && n>=8) (expect low bits of offset to put in r5)\n'
          '  a=r 1 a== 5 if a=d a> ${itos(rb - 1)} if\n'
          '    a=c a&= ${itos((1 << rb) - 1)} r=a 5            (save r in r5)\n'
          '    a=c a>>= ${itos(rb)} c=a\n'
          '    a=d a-= ${itos(rb)} d=a\n'
          '    a= 2 r=a 1                   (go to state 2)\n'
          '  endif endif\n'
          '\n';
    }
    pcomp += '''
  (if state==2 && n>=m) (expect m offset bits)
  a=r 1 a== 2 if a=r 3 a>d ifnot
    a=c r=a 6 a=d r=a 7          (save c=bits, d=n in r6,r7)
    b=r 3 a= 1 a<<=b d=a         (d=1<<m)
    a-- a&=c a+=d                (d=offset=bits&((1<<m)-1)|(1<<m))
''';
    if (rb != 0) {
      pcomp += '    a<<= ${itos(rb)} d=r 5 a+=d a-= ${itos((1 << rb) - 1)}\n';
    }
    pcomp += '''
    d=a b=r 4 a=b a-=d c=a       (c=p=(b=ptr)-offset)

    (while len-- (copy and output match d bytes from *c to *b))
    d=r 2 do a=d a> 0 if d--
      a=*c *b=a c++ b++          (buf[ptr++]-buf[p++])
''';
    if (!doe8) pcomp += ' out\n';
    pcomp += '''
    forever endif
    a=b r=a 4

    a=r 6 b=r 3 a>>=b c=a        (bits>>=m)
    a=r 7 a-=b d=a               (n-=m)
    a=0 r=a 1                    (state=0)
  endif endif

  (while state==3 && n>=2 (expect literal length))
  do a=r 1 a== 3 if a=d a> 1 if
    a=c a&= 1 a== 1 if         (if bits&1)
      a=c a>>= 1 c=a              (bits>>=1)
      b=r 2 a&= 1 a+=b a+=b r=a 2 (len+=len+(bits&1))
      a=c a>>= 1 c=a              (bits>>=1)
      d-- d--                     (n-=2)
    else
      a=c a>>= 1 c=a              (bits>>=1)
      d--                         (--n)
      a= 4 r=a 1                  (state=4)
    endif
  forever endif endif

  (if state==4 && n>=8 (expect len literals))
  a=r 1 a== 4 if a=d a> 7 if
    b=r 4 a=c *b=a
''';
    if (!doe8) pcomp += ' out\n';
    pcomp += '''
    b++ a=b r=a 4                 (buf[ptr++]=bits)
    a=c a>>= 8 c=a                (bits>>=8)
    a=d a-= 8 d=a                 (n-=8)
    a=r 2 a-- r=a 2 a== 0 if      (if --len<1)
      a=0 r=a 1                     (state=0)
    endif
  endif endif
  halt
end
''';
  } else if (level == 2) {
    hdr = r'comp 9 16 0 $1+20 ';
    pcomp = '''
pcomp lzpre c ;
  (Decode LZ77: d=state, M=output buffer, b=size)
  a> 255 if (at EOF decode e8e9 and output)
''';
    if (doe8) pcomp += _e8e9Decode2;
    pcomp += '''
    b=0 c=0 d=0 a=0 r=a 1 r=a 2 (reset state)
  halt
  endif

  (in state d==0, expect a new code)
  (put length in r1 and initial part of offset in r2)
  c=a a=d a== 0 if
    a=c a>>= 6 a++ d=a
    a== 1 if (literal?)
      a+=c r=a 1 a=0 r=a 2
    else (3 to 5 byte match)
      d++ a=c a&= 63 a+= \$3 r=a 1 a=0 r=a 2
    endif
  else
    a== 1 if (writing literal)
      a=c *b=a b++
''';
    if (!doe8) pcomp += ' out\n';
    pcomp += '''
      a=r 1 a-- a== 0 if d=0 endif r=a 1 (if (--len==0) state=0)
    else
      a> 2 if (reading offset)
        a=r 2 a<<= 8 a|=c r=a 2 d-- (off=off<<8|c, --state)
      else (state==2, write match)
        a=r 2 a<<= 8 a|=c c=a a=b a-=c a-- c=a (c=i-off-1)
        d=r 1 (d=len)
        do (copy and output d=len bytes)
          a=*c *b=a c++ b++
''';
    if (!doe8) pcomp += ' out\n';
    pcomp += '''
        d-- a=d a> 0 while
        (d=state=0. off, len don't matter)
      endif
    endif
  endif
  halt
end
''';
  } else if (level == 3) {
    hdr = r'comp 9 16 $1+20 $1+20 ';
    pcomp = '''
pcomp bwtrle c ;

  (read BWT, index into M, size in b)
  a> 255 ifnot
    *b=a b++

  (inverse BWT)
  elsel

    (index in last 4 bytes, put in c and R1)
    b-- a=*b
    b-- a<<= 8 a+=*b
    b-- a<<= 8 a+=*b
    b-- a<<= 8 a+=*b c=a r=a 1

    (save size in R2)
    a=b r=a 2

    (count bytes in H[~1..~255, ~0])
    do
      a=b a> 0 if
        b-- a=*b a++ a&= 255 d=a d! *d++
      forever
    endif

    (cumulative counts: H[~i=0..255] = count of bytes before i)
    d=0 d! *d= 1 a=0
    do
      a+=*d *d=a d--
    d<>a a! a> 255 a! d<>a until

    (build first part of linked list in H[0..idx-1])
    b=0 do
      a=c a>b if
        d=*b d! *d++ d=*d d-- *d=b
      b++ forever
    endif

    (rest of list in H[idx+1..n-1])
    b=c b++ c=r 2 do
      a=c a>b if
        d=*b d! *d++ d=*d d-- *d=b
      b++ forever
    endif

''';
    if (args[0] <= 4) {
      pcomp += '''
    (copy M to low 8 bits of H to reduce cache misses in next loop)
    b=0 do
      a=c a>b if
        d=b a=*d a<<= 8 a+=*b *d=a
      b++ forever
    endif

    (traverse list and output or copy to M)
    d=r 1 b=0 do
      a=d a== 0 ifnot
        a=*d a>>= 8 d=a
''';
      if (doe8) {
        pcomp += ' *b=*d b++\n';
      } else {
        pcomp += ' a=*d out\n';
      }
      pcomp += '''
      forever
    endif

''';
      if (doe8) {
        pcomp += '''
    (e8e9 transform to out)
    d=b b=0 do (for b=0..d-1, d = end of buf)
      a=b a==d ifnot
        a+= 4 a<d if
          a=*b a&= 254 a== 232 if
            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if
              b-- a=*b
              b-- a<<= 8 a+=*b
              b-- a<<= 8 a+=*b
              a-=b a++
              *b=a a>>= 8 b++
              *b=a a>>= 8 b++
              *b=a b++
            endif
            b=c
          endif
        endif
        a=*b out b++
      forever
    endif
''';
      }
      pcomp += '''
  endif
  halt
end
''';
    } else {
      if (doe8) {
        pcomp += '''
    (R2 = output size without EOS)
    a=r 2 a-- r=a 2

    (traverse list (d = IBWT pointer) and output inverse e8e9)
    (C = offset = 0..R2-1)
    (R4 = last 4 bytes shifted in from MSB end)
    (R5 = temp pending output byte)
    c=0 d=r 1 do
      a=d a== 0 ifnot
        d=*d

        (store byte in R4 and shift out to R5)
        b=d a=*b a<<= 24 b=a
        a=r 4 r=a 5 a>>= 8 a|=b r=a 4

        (if E8|E9 xx xx xx 00|FF in R4:R5 then subtract c from x)
        a=c a> 3 if
          a=r 5 a&= 254 a== 232 if
            a=r 4 a>>= 24 b=a a++ a&= 254 a< 2 if
              a=r 4 a-=c a+= 4 a<<= 8 a>>= 8
              b<>a a<<= 24 a+=b r=a 4
            endif
          endif
        endif

        (output buffered byte)
        a=c a> 3 if a=r 5 out endif c++

      forever
    endif

    (output up to 4 pending bytes in R4)
    b=r 4
    a=c a> 3 a=b if out endif a>>= 8 b=a
    a=c a> 2 a=b if out endif a>>= 8 b=a
    a=c a> 1 a=b if out endif a>>= 8 b=a
    a=c a> 0 a=b if out endif

  endif
  halt
end
''';
      } else {
        pcomp += '''
    (traverse list and output)
    d=r 1 do
      a=d a== 0 ifnot
        d=*d
        b=d a=*b out
      forever
    endif
  endif
  halt
end
''';
      }
    }
  } else if (level == 0) {
    hdr = 'comp 9 16 0 0 ';
    if (doe8) {
      pcomp = '''
pcomp e8e9 d ;
  a> 255 if
    a=c a> 4 if
      c= 4
    else
      a! a+= 5 a<<= 3 d=a a=b a>>=d b=a
    endif
    do a=c a> 0 if
      a=b out a>>= 8 b=a c--
    forever endif
  else
    *b=b a<<= 24 d=a a=b a>>= 8 a+=d b=a c++
    a=c a> 4 if
      a=*b out
      a&= 254 a== 232 if
        a=b a>>= 24 a++ a&= 254 a== 0 if
          a=b a>>= 24 a<<= 24 d=a
          a=b a-=c a+= 5
          a<<= 8 a>>= 8 a|=d b=a
        endif
      endif
    endif
  endif
  halt
end
''';
    } else {
      pcomp = 'end\n';
    }
  } else {
    zpaqError('Unsupported method');
  }

  // Build context model (comp, hcomp)
  var ncomp = 0;
  final membits = args[0] + 20;
  var sb = 5;
  final comp = StringBuffer();
  final hcomp = StringBuffer('hcomp\nc-- *c=a a+= 255 d=a *d=c\n');
  if (level == 2) {
    hcomp.write('  (decode lz77 into M. Codes:\n'
        '  00xxxxxx = literal length xxxxxx+1\n'
        '  xx......, xx > 0 = match with xx offset bytes to follow)\n'
        '\n'
        '  a=r 1 a== 0 if (init)\n'
        '    a= ${itos(111 + 57 * (doe8 ? 1 : 0))} (skip post code)\n'
        '  else a== 1 if  (new code?)\n'
        '    a=*c r=a 2  (save code in R2)\n'
        '    a> 63 if a>>= 6 a++ a++  (match)\n'
        '    else a++ a++ endif  (literal)\n'
        '  else (read rest of code)\n'
        '    a--\n'
        '  endif endif\n'
        '  r=a 1  (R1 = 1+expected bytes to next code)\n');
  }

  while (mp < method.length && ncomp < 254) {
    final v = <int>[method.codeUnitAt(mp++)];
    if (_isDigit(ch(mp))) {
      v.add(ch(mp++) - 48);
      while (_isDigit(ch(mp)) || ch(mp) == 44 || ch(mp) == 46) {
        if (_isDigit(ch(mp))) {
          v[v.length - 1] = v.last * 10 + ch(mp++) - 48;
        } else {
          v.add(0);
          ++mp;
        }
      }
    }
    final cmd = String.fromCharCode(v[0]);

    // c: context model
    if (cmd == 'c') {
      while (v.length < 3) {
        v.add(0);
      }
      comp.write('${itos(ncomp)} ');
      sb = 11;
      if (v[2] < 256) {
        sb += lg(v[2]);
      } else {
        sb += 6;
      }
      for (var i = 3; i < v.length; ++i) {
        if (v[i] < 512) sb += _nbits(v[i]) * 3 ~/ 4;
      }
      if (sb > membits) sb = membits;
      if (v[1] % 1000 == 0) {
        comp.write('icm ${itos(sb - 6 - v[1] ~/ 1000)}\n');
      } else {
        comp.write(
            'cm ${itos(sb - 2 - v[1] ~/ 1000)} ${itos(v[1] % 1000 - 1)}\n');
      }
      hcomp.write('d= ${itos(ncomp)} *d=0\n');
      if (v[2] > 1 && v[2] <= 255) {
        if (lg(v[2]) != lg(v[2] - 1)) {
          hcomp.write('a=c a&= ${itos(v[2] - 1)} hashd\n');
        } else {
          hcomp.write('a=c a%= ${itos(v[2])} hashd\n');
        }
      } else if (v[2] >= 1000 && v[2] <= 1255) {
        hcomp.write('a= 255 a+= ${itos(v[2] - 1000)}'
            ' d=a a=*d a-=c a> 255 if a= 255 endif d= ${itos(ncomp)} hashd\n');
      }
      for (var i = 3; i < v.length; ++i) {
        if (i == 3) hcomp.write('b=c ');
        if (v[i] == 255) {
          hcomp.write('a=*b hashd\n');
        } else if (v[i] > 0 && v[i] < 255) {
          hcomp.write('a=*b a&= ${itos(v[i])} hashd\n');
        } else if (v[i] >= 256 && v[i] < 512) {
          hcomp.write('a=r 1 a> 1 if\n'
              '  a=r 2 a< 64 if\n'
              '    a=*b ');
          if (v[i] < 511) hcomp.write('a&= ${itos(v[i] - 256)}');
          hcomp.write(' hashd\n'
              '  else\n'
              '    a>>= 6 hashd a=r 1 hashd\n'
              '  endif\n'
              'else\n'
              '  a= 255 hashd a=r 2 hashd\n'
              'endif\n');
        } else if (v[i] >= 1256) {
          hcomp.write('a= ${itos(((v[i] - 1000) >> 8) & 255)} a<<= 8 a+= '
              '${itos((v[i] - 1000) & 255)} a+=b b=a\n');
        } else if (v[i] > 1000) {
          hcomp.write('a= ${itos(v[i] - 1000)} a+=b b=a\n');
        }
        if (i < v.length - 1 && v[i] < 512) hcomp.write('b++ ');
      }
      ++ncomp;
    }

    // m,8,24: MIX, t,8,24: MIX2, s,8,32,255: SSE
    if ((cmd == 'm' || cmd == 't' || cmd == 's') &&
        ncomp > (cmd == 't' ? 1 : 0)) {
      if (v.length <= 1) v.add(8);
      if (v.length <= 2) v.add(24 + 8 * (cmd == 's' ? 1 : 0));
      if (cmd == 's' && v.length <= 3) v.add(255);
      comp.write(itos(ncomp));
      sb = 5 + v[1] * 3 ~/ 4;
      if (cmd == 'm') {
        comp.write(' mix ${itos(v[1])} 0 ${itos(ncomp)} ${itos(v[2])} 255\n');
      } else if (cmd == 't') {
        comp.write(' mix2 ${itos(v[1])} ${itos(ncomp - 1)} ${itos(ncomp - 2)}'
            ' ${itos(v[2])} 255\n');
      } else {
        comp.write(' sse ${itos(v[1])} ${itos(ncomp - 1)} ${itos(v[2])}'
            ' ${itos(v[3])}\n');
      }
      if (v[1] > 8) {
        hcomp.write('d= ${itos(ncomp)} *d=0 b=c a=0\n');
        for (; v[1] >= 16; v[1] -= 8) {
          hcomp.write('a<<= 8 a+=*b');
          if (v[1] > 16) hcomp.write(' b++');
          hcomp.write('\n');
        }
        if (v[1] > 8) {
          hcomp.write('a<<= 8 a+=*b a>>= ${itos(16 - v[1])}\n');
        }
        hcomp.write('a<<= 8 *d=a\n');
      }
      ++ncomp;
    }

    // i: ISSE chain with order increasing by N1,N2...
    if (cmd == 'i' && ncomp > 0) {
      hcomp.write('d= ${itos(ncomp - 1)} b=c a=*d d++\n');
      for (var i = 1; i < v.length && ncomp < 254; ++i) {
        for (var j = 0; j < v[i] % 10; ++j) {
          hcomp.write('hash ');
          if (i < v.length - 1 || j < v[i] % 10 - 1) hcomp.write('b++ ');
          sb += 6;
        }
        hcomp.write('*d=a');
        if (i < v.length - 1) hcomp.write(' d++');
        hcomp.write('\n');
        if (sb > membits) sb = membits;
        comp.write('${itos(ncomp)} isse ${itos(sb - 6 - v[i] ~/ 10)}'
            ' ${itos(ncomp - 1)}\n');
        ++ncomp;
      }
    }

    // a24,0,0: MATCH. N1=hash multiplier. N2,N3=halve buf, table.
    if (cmd == 'a') {
      if (v.length <= 1) v.add(24);
      while (v.length < 4) {
        v.add(0);
      }
      comp.write('${itos(ncomp)} match ${itos(membits - v[3] - 2)}'
          ' ${itos(membits - v[2])}\n');
      hcomp.write('d= ${itos(ncomp)} a=*d a*= ${itos(v[1])}'
          ' a+=*c a++ *d=a\n');
      sb = 5 + (membits - v[2]) * 3 ~/ 4;
      ++ncomp;
    }

    // w1,65,26,223,20,0: ICM-ISSE chain of word contexts.
    if (cmd == 'w') {
      if (v.length <= 1) v.add(1);
      if (v.length <= 2) v.add(65);
      if (v.length <= 3) v.add(26);
      if (v.length <= 4) v.add(223);
      if (v.length <= 5) v.add(20);
      if (v.length <= 6) v.add(0);
      comp.write('${itos(ncomp)} icm ${itos(membits - 6 - v[6])}\n');
      for (var i = 1; i < v[1]; ++i) {
        comp.write('${itos(ncomp + i)} isse ${itos(membits - 6 - v[6])}'
            ' ${itos(ncomp + i - 1)}\n');
      }
      hcomp.write('a=*c a&= ${itos(v[4])} a-= ${itos(v[2])} a&= 255 a< '
          '${itos(v[3])} if\n');
      for (var i = 0; i < v[1]; ++i) {
        if (i == 0) {
          hcomp.write('  d= ${itos(ncomp)}');
        } else {
          hcomp.write('  d++');
        }
        hcomp.write(' a=*d a*= ${itos(v[5])} a+=*c a++ *d=a\n');
      }
      hcomp.write('else\n');
      for (var i = v[1] - 1; i > 0; --i) {
        hcomp.write('  d= ${itos(ncomp + i - 1)} a=*d d++ *d=a\n');
      }
      hcomp.write('  d= ${itos(ncomp)} *d=0\nendif\n');
      ncomp += v[1] - 1;
      sb = membits - v[6];
      ++ncomp;
    }
  }
  return '$hdr${itos(ncomp)}\n$comp${hcomp}halt\n$pcomp';
}

/// Expands a numeric compression level ("0".."5" plus optional block
/// size digits and ",redundancy,type") to an explicit method, as libzpaq
/// compressBlock() does, analyzing the data for level 5.
String expandMethod(String method, Uint8List data, int n) {
  final arg0 = _max(lg(n + 4095) - 20, 0);
  var type = 0;
  if (!_isDigit(method.codeUnitAt(0))) return method;
  var commas = 0;
  final arg = [0, 0, 0, 0];
  for (var i = 1; i < method.length && commas < 4; ++i) {
    final c = method.codeUnitAt(i);
    if (c == 44 || c == 46) {
      ++commas;
    } else if (_isDigit(c)) {
      arg[commas] = arg[commas] * 10 + c - 48;
    }
  }
  if (commas == 0) {
    type = 512;
  } else {
    type = arg[1] * 4 + arg[2];
  }

  final level = method.codeUnitAt(0) - 48;
  final doe8 = (type & 2) * 2;
  var m = 'x${itos(arg0)}';
  final htsz = ',${itos(19 + arg0 + (arg0 <= 6 ? 1 : 0))}';
  final sasz = ',${itos(21 + arg0)}';
  if (level == 0) {
    m = '0${itos(arg0)},0';
  } else if (level == 1) {
    if (type < 40) {
      m += ',0';
    } else {
      m += ',${itos(1 + doe8)},';
      if (type < 80) {
        m += '4,0,1,15';
      } else if (type < 128) {
        m += '4,0,2,16';
      } else if (type < 256) {
        m += '4,0,2$htsz';
      } else if (type < 960) {
        m += '5,0,3$htsz';
      } else {
        m += '6,0,3$htsz';
      }
    }
  } else if (level == 2) {
    if (type < 32) {
      m += ',0';
    } else {
      m += ',${itos(1 + doe8)},';
      if (type < 64) {
        m += '4,0,3$htsz';
      } else {
        m += '4,0,7$sasz,1';
      }
    }
  } else if (level == 3) {
    if (type < 20) {
      m += ',0';
    } else if (type < 48) {
      m += ',${itos(1 + doe8)},4,0,3$htsz';
    } else if (type >= 640 || (type & 1) != 0) {
      m += ',${itos(3 + doe8)}ci1';
    } else {
      m += ',${itos(2 + doe8)},12,0,7$sasz,1c0,0,511i2';
    }
  } else if (level == 4) {
    if (type < 12) {
      m += ',0';
    } else if (type < 24) {
      m += ',${itos(1 + doe8)},4,0,3$htsz';
    } else if (type < 48) {
      m += ',${itos(2 + doe8)},5,0,7${sasz}1c0,0,511';
    } else if (type < 900) {
      m += ',${itos(doe8)}ci1,1,1,1,2a';
      if ((type & 1) != 0) m += 'w';
      m += 'm';
    } else {
      m += ',${itos(3 + doe8)}ci1';
    }
  } else {
    m += ',${itos(doe8)}';
    if ((type & 1) != 0) {
      m += 'w2c0,1010,255i1';
    } else {
      m += 'w1i1';
    }
    m += 'c256ci1,1,1,1,1,1,2a';
    const nr = 1 << 12;
    final pt = Int32List(256);
    final r = Int32List(nr);
    for (var i = 0; i < n; ++i) {
      final k = i - pt[data[i]];
      if (k > 0 && k < nr) ++r[k];
      pt[data[i]] = i;
    }
    var n1 = n - r[1] - r[2] - r[3];
    for (var i = 0; i < 2; ++i) {
      var period = 0;
      var score = 0.0;
      var t = 0;
      for (var j = 5; j < nr && t < n1; ++j) {
        final s = r[j] / (256.0 + n1 - t);
        if (s > score) {
          score = s;
          period = j;
        }
        t += r[j];
      }
      if (period > 4 && score > 0.1) {
        m += 'c0,0,${itos(999 + period)},255i1';
        if (period <= 255) m += 'c0,${itos(period)}i1';
        n1 -= r[period];
        r[period] = 0;
      } else {
        break;
      }
    }
    m += 'c0,2,0,255i1c0,3,0,0,255i1c0,4,0,0,0,255i1mm16ts19t0';
  }
  return m;
}

int _max(int a, int b) => a > b ? a : b;

/// Compresses [input] as one ZPAQ block with a single segment, appending to
/// [out]. [method] is a level ("0".."5" with optional ",R,T") or an explicit
/// method string ("x...", "0..."). Mirrors libzpaq::compressBlock().
///
/// Note: the input buffer may be modified in place (E8E9 filter).
///
/// [tables] keeps the LZ77 hash table from block to block.
void compressBlock(ZBuffer input, ZWriter out, String method,
    {String filename = '',
    String? comment,
    bool dosha1 = true,
    LzHashTables? tables}) {
  final n = input.size;
  Uint8List? sha1;
  if (dosha1) sha1 = Sha1.hash(input.data, 0, n);

  method = expandMethod(method, input.data, n);
  final args = List<int>.filled(9, 0);
  final config = makeConfig(method, args);
  if (n > (0x100000 << args[0]) - 4096) {
    zpaqError('block too big for method $method');
  }
  final co = Compressor();
  co.output = out;
  co.writeTag();
  co.startBlockConfig(config, args);
  var cs = itos(n);
  if (comment != null) cs = '$cs $comment';
  co.startSegment(filename, cs);
  if (args[1] >= 1 && args[1] <= 7 && args[1] != 4) {
    final lz = LzBuffer(input, args, tables?.take);
    co.input = lz;
    co.compress();
    tables?.release(lz.clearWritten());
  } else {
    if (args[1] >= 4 && args[1] <= 7) e8e9(input.data, n);
    co.input = MemoryReader(input.data, 0, n);
    co.compress();
  }
  co.endSegment(sha1);
  co.endBlock();
}
