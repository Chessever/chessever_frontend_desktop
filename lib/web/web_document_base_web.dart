import 'package:web/web.dart' as web;

/// `document.baseURI`, which honours the `<base href>` in index.html.
Uri webDocumentBase() => Uri.parse(web.document.baseURI);
