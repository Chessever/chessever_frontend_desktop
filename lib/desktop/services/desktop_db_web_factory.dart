import 'package:sqflite/sqflite.dart' show DatabaseFactory;

/// Native builds never use the browser database factory; see
/// desktop_db_web_factory_web.dart for the web build's.
DatabaseFactory webDatabaseFactory() =>
    throw UnsupportedError('The web database factory exists only on the web.');
