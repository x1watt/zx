import 'package:flutter_test/flutter_test.dart';
import 'package:zx/zx.dart';
import 'package:zx_app/src/dialogs/compression_form.dart';
import 'package:zx_app/src/formats.dart';

void main() {
  test('folderNameFor strips archive extensions', () {
    expect(folderNameFor('/a/b/photos.zip'), 'photos');
    expect(folderNameFor('/a/src.tar.gz'), 'src');
    expect(folderNameFor('/a/src.TAR.XZ'), 'src');
    expect(folderNameFor('/a/src.tgz'), 'src');
    expect(folderNameFor('/a/src.tar'), 'src');
    expect(folderNameFor('/a/big.7z.001'), 'big');
    expect(folderNameFor('/a/big.part1.rar'), 'big');
    expect(folderNameFor('/a/big.part01.rar'), 'big');
    expect(folderNameFor('/a/notes.txt.gz'), 'notes.txt');
    expect(folderNameFor('/a/data.bz2'), 'data');
    expect(folderNameFor('/a/my.backup.7z'), 'my.backup');
    expect(folderNameFor('/a/old.lzh'), 'old');
    expect(folderNameFor('/a/noext'), 'noext');
    expect(folderNameFor('/a/.7z'), '.7z');
  });

  test('looksLikeArchive', () {
    expect(looksLikeArchive('x.7z'), isTrue);
    expect(looksLikeArchive('x.TAR.BZ2'), isTrue);
    expect(looksLikeArchive('x.7z.002'), isTrue);
    expect(looksLikeArchive('x.r01'), isTrue);
    expect(looksLikeArchive('x.txt'), isFalse);
  });

  test('every new format maps back from its ZxArchive name', () {
    for (final f in kNewFormats) {
      final outer = switch (f.id) {
        'tar.gz' => ['gzip'],
        'tar.bz2' => ['bzip2'],
        'tar.xz' => ['xz'],
        _ => <String>[],
      };
      final name = switch (f.id) {
        'tar.gz' || 'tar.bz2' || 'tar.xz' => 'tar',
        _ => f.createFormat,
      };
      expect(formatForArchive(name, outer)?.id, f.id);
    }
  });

  test('zpaq: methods instead of levels, the extension and MIME type', () {
    final f = newFormatById('zpaq');
    expect(f.createFormat, 'zpaq');
    final o = (CompressionSettings(level: 9)..method = '3').toOptions(f);
    expect(o.level, isNull);
    expect(o.switches, {'m': '3'});
    expect(methodLabel(f, '5'), contains('slow'));
    expect(looksLikeArchive('backup.zpaq'), isTrue);
    expect(folderNameFor('backup.zpaq'), 'backup');
    expect(kArchiveMimeTypes, contains('application/x-zpaq'));
  });

  test('compression settings become ZxOptions', () {
    final s = CompressionSettings(level: 9)
      ..method = 'PPMd'
      ..password = 'pw'
      ..encryptNames = true
      ..solid = false;
    final o = s.toOptions(newFormatById('7z'));
    expect(o.level, 9);
    expect(o.method, 'PPMd');
    expect(o.password, 'pw');
    expect(o.encryptHeaders, isTrue);
    expect(o.solid, isFalse);

    final z = (CompressionSettings()..password = 'pw').toOptions(
      newFormatById('zip'),
    );
    expect(z.switches['em'], 'AES256');
    expect(z.encryptHeaders, isNull);

    final l = (CompressionSettings()..method = 'lh7').toOptions(
      newFormatById('lzh'),
    );
    expect(l.method, isNull);
    expect(l.switches['m'], 'lh7');

    final t = (CompressionSettings()..password = 'x').toOptions(
      newFormatById('tar.gz'),
    );
    expect(t.password, isNull);
    expect(const ZxOptions().level, isNull);
  });
}
