/// Shared metrics for the desktop shell's top chrome.
///
/// The tab strip (`DesktopTabBar`) and the sidebar header band both stand
/// this tall. Sharing one constant keeps their bottom borders collinear so
/// the 1px divider reads as a single continuous horizontal seam running the
/// full window width — meeting the sidebar's vertical right edge in a clean
/// corner junction instead of stepping down where the two bars meet.
const double kDesktopChromeBarHeight = 46;
