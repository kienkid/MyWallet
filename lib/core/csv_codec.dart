/// Minimal RFC 4180 CSV codec. Kept in-house (instead of a package) so the
/// export/import format cannot change when a dependency changes its API.
class CsvParseException implements Exception {
  CsvParseException(this.record, this.code);
  final int record; // 1-based record number (header = 1)
  final String code; // unexpectedQuote | unterminatedQuote
  @override
  String toString() => 'CsvParseException(record $record, $code)';
}

String _escape(String v) {
  final needsQuotes = v.contains(RegExp(r'[",\r\n]')) || v != v.trim();
  return needsQuotes ? '"${v.replaceAll('"', '""')}"' : v;
}

/// Encodes rows using comma separator and CRLF line endings.
String encodeCsv(List<List<String>> rows) {
  final b = StringBuffer();
  for (final r in rows) {
    b.write(r.map(_escape).join(','));
    b.write('\r\n');
  }
  return b.toString();
}

/// Decodes CSV text. Strips a UTF-8 BOM, accepts CRLF/LF, quoted fields with
/// embedded commas, quotes ("") and line breaks. Blank lines are ignored.
List<List<String>> decodeCsv(String input) {
  var s = input;
  if (s.startsWith('\uFEFF')) s = s.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var quotedField = false;
  var i = 0;

  void endField() {
    row.add(field.toString());
    field.clear();
    quotedField = false;
  }

  void endRow() {
    endField();
    if (!(row.length == 1 && row.first.isEmpty)) rows.add(row);
    row = <String>[];
  }

  while (i < s.length) {
    final c = s[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      if (field.isEmpty && !quotedField) {
        inQuotes = true;
        quotedField = true;
        i++;
        continue;
      }
      throw CsvParseException(rows.length + 1, 'unexpectedQuote');
    }
    if (c == ',') {
      endField();
      i++;
      continue;
    }
    if (c == '\r' || c == '\n') {
      endRow();
      if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      i++;
      continue;
    }
    field.write(c);
    i++;
  }
  if (inQuotes) throw CsvParseException(rows.length + 1, 'unterminatedQuote');
  if (field.isNotEmpty || row.isNotEmpty || quotedField) endRow();
  return rows;
}
