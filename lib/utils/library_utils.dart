/// Library-related constants and utility functions.
///
/// This file contains shared constants and helper methods used across
/// library-related screens and widgets.
library;

/// Maximum number of books/folders a free user can create.
/// After reaching this limit, users must upgrade to premium.
const int kFreeBookCreationLimit = 3;

/// Maximum number of saved analyses a free user can hold across every
/// folder. Inserts past this count surface the premium paywall instead of
/// silently succeeding. Mobile and desktop share the same cap so the limit
/// follows the user across devices.
const int kFreeSavedGamesLimit = 10;
