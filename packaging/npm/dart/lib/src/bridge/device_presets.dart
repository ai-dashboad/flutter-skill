/// Comprehensive device preset database for CDP device emulation.
///
/// Contains 143+ device definitions with viewport dimensions, scale factors,
/// and realistic user agent strings.
class DevicePreset {
  final int width;
  final int height;
  final double deviceScaleFactor;
  final bool isMobile;
  final bool hasTouch;
  final String? userAgent;

  const DevicePreset({
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
    required this.isMobile,
    required this.hasTouch,
    this.userAgent,
  });

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'deviceScaleFactor': deviceScaleFactor,
        'isMobile': isMobile,
        'hasTouch': hasTouch,
        'userAgent': userAgent,
      };
}

// Common UA fragments
const _chromeVer = '130.0.6723.92';
const _safariVer = '605.1.15';
const _chromeDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_chromeVer Safari/537.36';
const _chromeMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_chromeVer Safari/537.36';
const _firefoxDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0';
const _firefoxMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14.5; rv:132.0) Gecko/20100101 Firefox/132.0';
const _safariMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/$_safariVer (KHTML, like Gecko) Version/19.2 Safari/$_safariVer';
const _edgeDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_chromeVer Safari/537.36 Edg/$_chromeVer';

String _iosUA(String osVer) =>
    'Mozilla/5.0 (iPhone; CPU iPhone OS ${osVer.replaceAll('.', '_')} like Mac OS X) AppleWebKit/$_safariVer (KHTML, like Gecko) Version/19.2 Mobile/15E148 Safari/$_safariVer';
String _ipadUA(String osVer) =>
    'Mozilla/5.0 (iPad; CPU OS ${osVer.replaceAll('.', '_')} like Mac OS X) AppleWebKit/$_safariVer (KHTML, like Gecko) Version/19.2 Mobile/15E148 Safari/$_safariVer';
String _androidUA(String device, String androidVer) =>
    'Mozilla/5.0 (Linux; Android $androidVer; $device) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_chromeVer Mobile Safari/537.36';
String _androidTabletUA(String device, String androidVer) =>
    'Mozilla/5.0 (Linux; Android $androidVer; $device) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_chromeVer Safari/537.36';

/// The canonical device preset database. Keys are lowercase, hyphenated.
final Map<String, DevicePreset> devicePresets = _buildPresets();

Map<String, DevicePreset> _buildPresets() {
  final m = <String, DevicePreset>{};

  void add(String name, int w, int h, double s, bool mobile, bool touch,
      String? ua) {
    m[name] = DevicePreset(
      width: w,
      height: h,
      deviceScaleFactor: s,
      isMobile: mobile,
      hasTouch: touch,
      userAgent: ua,
    );
  }

  // ── iPhones ──────────────────────────────────────────────
  final ios18 = '18.2';
  final ios17 = '17.6';
  final ios16 = '16.6';
  final ios15 = '15.8';

  // iPhone 16 series
  add('iphone-16-pro-max', 440, 956, 3.0, true, true, _iosUA(ios18));
  add('iphone-16-pro', 402, 874, 3.0, true, true, _iosUA(ios18));
  add('iphone-16-plus', 430, 932, 3.0, true, true, _iosUA(ios18));
  add('iphone-16', 393, 852, 3.0, true, true, _iosUA(ios18));

  // iPhone 15 series
  add('iphone-15-pro-max', 430, 932, 3.0, true, true, _iosUA(ios18));
  add('iphone-15-pro', 393, 852, 3.0, true, true, _iosUA(ios18));
  add('iphone-15-plus', 430, 932, 3.0, true, true, _iosUA(ios18));
  add('iphone-15', 393, 852, 3.0, true, true, _iosUA(ios18));

  // iPhone 14 series
  add('iphone-14-pro-max', 430, 932, 3.0, true, true, _iosUA(ios17));
  add('iphone-14-pro', 393, 852, 3.0, true, true, _iosUA(ios17));
  add('iphone-14-plus', 428, 926, 3.0, true, true, _iosUA(ios17));
  add('iphone-14', 390, 844, 3.0, true, true, _iosUA(ios17));

  // iPhone 13 series
  add('iphone-13-pro-max', 428, 926, 3.0, true, true, _iosUA(ios17));
  add('iphone-13-pro', 390, 844, 3.0, true, true, _iosUA(ios17));
  add('iphone-13-mini', 375, 812, 3.0, true, true, _iosUA(ios17));
  add('iphone-13', 390, 844, 3.0, true, true, _iosUA(ios17));

  // iPhone 12 series
  add('iphone-12-pro-max', 428, 926, 3.0, true, true, _iosUA(ios17));
  add('iphone-12-pro', 390, 844, 3.0, true, true, _iosUA(ios17));
  add('iphone-12-mini', 375, 812, 3.0, true, true, _iosUA(ios17));
  add('iphone-12', 390, 844, 3.0, true, true, _iosUA(ios17));

  // iPhone 11 series
  add('iphone-11-pro-max', 414, 896, 3.0, true, true, _iosUA(ios16));
  add('iphone-11-pro', 375, 812, 3.0, true, true, _iosUA(ios16));
  add('iphone-11', 414, 896, 2.0, true, true, _iosUA(ios16));

  // iPhone SE & older
  add('iphone-se-3rd', 375, 667, 2.0, true, true, _iosUA(ios18));
  add('iphone-se-2nd', 375, 667, 2.0, true, true, _iosUA(ios17));
  add('iphone-se-1st', 320, 568, 2.0, true, true, _iosUA(ios15));
  add('iphone-xr', 414, 896, 2.0, true, true, _iosUA(ios16));
  add('iphone-xs-max', 414, 896, 3.0, true, true, _iosUA(ios16));
  add('iphone-xs', 375, 812, 3.0, true, true, _iosUA(ios16));
  add('iphone-x', 375, 812, 3.0, true, true, _iosUA(ios15));
  add('iphone-8-plus', 414, 736, 3.0, true, true, _iosUA(ios15));
  add('iphone-8', 375, 667, 2.0, true, true, _iosUA(ios15));

  // ── Google Pixel ─────────────────────────────────────────
  add('pixel-9-pro-xl', 412, 915, 3.5, true, true,
      _androidUA('Pixel 9 Pro XL', '15'));
  add('pixel-9-pro', 412, 915, 3.0, true, true,
      _androidUA('Pixel 9 Pro', '15'));
  add('pixel-9', 412, 915, 2.625, true, true, _androidUA('Pixel 9', '15'));
  add('pixel-8-pro', 412, 915, 3.5, true, true,
      _androidUA('Pixel 8 Pro', '14'));
  add('pixel-8', 412, 915, 2.625, true, true, _androidUA('Pixel 8', '14'));
  add('pixel-7-pro', 412, 892, 3.5, true, true,
      _androidUA('Pixel 7 Pro', '14'));
  add('pixel-7', 412, 915, 2.625, true, true, _androidUA('Pixel 7', '14'));
  add('pixel-7a', 412, 915, 2.625, true, true, _androidUA('Pixel 7a', '14'));
  add('pixel-6-pro', 412, 892, 3.5, true, true,
      _androidUA('Pixel 6 Pro', '14'));
  add('pixel-6', 412, 915, 2.625, true, true, _androidUA('Pixel 6', '14'));
  add('pixel-6a', 412, 892, 2.625, true, true, _androidUA('Pixel 6a', '14'));
  add('pixel-5', 393, 851, 2.75, true, true, _androidUA('Pixel 5', '14'));
  add('pixel-4', 412, 869, 2.75, true, true, _androidUA('Pixel 4', '13'));
  add('pixel-4-xl', 412, 869, 3.5, true, true, _androidUA('Pixel 4 XL', '13'));

  // ── Samsung Galaxy S ─────────────────────────────────────
  add('galaxy-s24-ultra', 412, 915, 3.75, true, true,
      _androidUA('SM-S928B', '15'));
  add('galaxy-s24-plus', 412, 915, 3.0, true, true,
      _androidUA('SM-S926B', '15'));
  add('galaxy-s24', 412, 915, 2.625, true, true, _androidUA('SM-S921B', '15'));
  add('galaxy-s23-ultra', 412, 915, 3.75, true, true,
      _androidUA('SM-S918B', '14'));
  add('galaxy-s23-plus', 412, 915, 3.0, true, true,
      _androidUA('SM-S916B', '14'));
  add('galaxy-s23', 412, 915, 2.625, true, true, _androidUA('SM-S911B', '14'));
  add('galaxy-s22-ultra', 412, 915, 3.75, true, true,
      _androidUA('SM-S908B', '14'));
  add('galaxy-s22-plus', 412, 915, 3.0, true, true,
      _androidUA('SM-S906B', '14'));
  add('galaxy-s22', 412, 915, 2.625, true, true, _androidUA('SM-S901B', '14'));
  add('galaxy-s21-ultra', 412, 915, 3.75, true, true,
      _androidUA('SM-G998B', '14'));
  add('galaxy-s21-plus', 412, 915, 3.0, true, true,
      _androidUA('SM-G996B', '14'));
  add('galaxy-s21', 412, 915, 2.625, true, true, _androidUA('SM-G991B', '14'));

  // ── Samsung Galaxy Z ─────────────────────────────────────
  add('galaxy-z-fold-5', 373, 841, 3.0, true, true,
      _androidUA('SM-F946B', '14'));
  add('galaxy-z-fold-5-inner', 882, 1104, 2.0, true, true,
      _androidUA('SM-F946B', '14'));
  add('galaxy-z-fold-4', 373, 841, 3.0, true, true,
      _androidUA('SM-F936B', '14'));
  add('galaxy-z-fold-4-inner', 882, 1104, 2.0, true, true,
      _androidUA('SM-F936B', '14'));
  add('galaxy-z-flip-5', 412, 915, 3.0, true, true,
      _androidUA('SM-F731B', '14'));
  add('galaxy-z-flip-4', 412, 915, 3.0, true, true,
      _androidUA('SM-F721B', '14'));

  // ── Samsung Galaxy A ─────────────────────────────────────
  add('galaxy-a54', 412, 915, 2.625, true, true, _androidUA('SM-A546B', '14'));
  add('galaxy-a34', 412, 915, 2.625, true, true, _androidUA('SM-A346B', '14'));
  add('galaxy-a14', 412, 915, 2.0, true, true, _androidUA('SM-A146B', '14'));

  // ── OnePlus ──────────────────────────────────────────────
  add('oneplus-12', 412, 915, 3.5, true, true, _androidUA('CPH2573', '14'));
  add('oneplus-11', 412, 915, 3.5, true, true, _androidUA('CPH2449', '14'));
  add('oneplus-10-pro', 412, 915, 3.5, true, true, _androidUA('NE2210', '14'));
  add('oneplus-nord-3', 412, 915, 2.625, true, true,
      _androidUA('CPH2493', '14'));

  // ── Xiaomi ───────────────────────────────────────────────
  add('xiaomi-14-pro', 412, 915, 3.5, true, true,
      _androidUA('24015RN21C', '14'));
  add('xiaomi-13-pro', 412, 915, 3.5, true, true, _androidUA('2210132C', '14'));
  add('xiaomi-13', 412, 915, 2.625, true, true, _androidUA('2211133C', '14'));
  add('redmi-note-13-pro', 412, 915, 2.625, true, true,
      _androidUA('23090RA98C', '14'));
  add('redmi-note-12', 412, 915, 2.0, true, true,
      _androidUA('23021RAA2Y', '14'));
  add('poco-f5', 412, 915, 2.625, true, true, _androidUA('23049PCD8G', '14'));

  // ── Huawei ───────────────────────────────────────────────
  add('huawei-p60-pro', 412, 915, 3.5, true, true,
      _androidUA('MNA-AL00', '12'));
  add('huawei-mate-60-pro', 412, 915, 3.5, true, true,
      _androidUA('ALN-AL10', '12'));
  add('huawei-nova-12', 412, 915, 2.625, true, true,
      _androidUA('FOA-AL00', '12'));

  // ── Sony / Motorola / Others ─────────────────────────────
  add('sony-xperia-1-v', 412, 960, 3.5, true, true,
      _androidUA('XQ-DQ72', '14'));
  add('moto-edge-40-pro', 412, 915, 3.0, true, true,
      _androidUA('XT2301-4', '14'));
  add('nothing-phone-2', 412, 915, 2.625, true, true, _androidUA('A065', '14'));

  // ── iPads ────────────────────────────────────────────────
  add('ipad-pro-12.9', 1024, 1366, 2.0, true, true, _ipadUA(ios18));
  add('ipad-pro-11', 834, 1194, 2.0, true, true, _ipadUA(ios18));
  add('ipad-air-m2', 820, 1180, 2.0, true, true, _ipadUA(ios18));
  add('ipad-air-5th', 820, 1180, 2.0, true, true, _ipadUA(ios17));
  add('ipad-air-4th', 820, 1180, 2.0, true, true, _ipadUA(ios16));
  add('ipad-mini-6th', 744, 1133, 2.0, true, true, _ipadUA(ios18));
  add('ipad-mini-5th', 768, 1024, 2.0, true, true, _ipadUA(ios16));
  add('ipad-10th', 820, 1180, 2.0, true, true, _ipadUA(ios18));
  add('ipad-9th', 810, 1080, 2.0, true, true, _ipadUA(ios17));
  add('ipad-pro-12.9-landscape', 1366, 1024, 2.0, true, true, _ipadUA(ios18));
  add('ipad-pro-11-landscape', 1194, 834, 2.0, true, true, _ipadUA(ios18));

  // ── Android Tablets ──────────────────────────────────────
  add('galaxy-tab-s9-ultra', 1848, 2960, 2.0, true, true,
      _androidTabletUA('SM-X910', '14'));
  add('galaxy-tab-s9-plus', 1752, 2800, 2.0, true, true,
      _androidTabletUA('SM-X810', '14'));
  add('galaxy-tab-s9', 1600, 2560, 2.0, true, true,
      _androidTabletUA('SM-X710', '14'));
  add('galaxy-tab-s8-ultra', 1848, 2960, 2.0, true, true,
      _androidTabletUA('SM-X900', '14'));
  add('galaxy-tab-s8', 1600, 2560, 2.0, true, true,
      _androidTabletUA('SM-X700', '14'));
  add('galaxy-tab-s7', 1600, 2560, 2.0, true, true,
      _androidTabletUA('SM-T870', '13'));
  add('galaxy-tab-a9', 800, 1340, 1.5, true, true,
      _androidTabletUA('SM-X110', '14'));

  // ── Surface / Windows Tablets ────────────────────────────
  add('surface-pro-9', 1920, 1280, 2.0, true, true, _edgeDesktop);
  add('surface-pro-8', 1920, 1280, 2.0, true, true, _edgeDesktop);
  add('surface-pro-7', 1920, 1280, 2.0, true, true, _edgeDesktop);
  add('surface-go-3', 1920, 1280, 1.5, true, true, _edgeDesktop);
  add('surface-duo-2', 1344, 1892, 2.5, true, true,
      _androidUA('Surface Duo 2', '12'));

  // ── Amazon Kindle / Fire ─────────────────────────────────
  add('kindle-fire-hdx', 800, 1280, 2.0, true, true,
      _androidTabletUA('KFAPWI', '11'));
  add('fire-hd-10', 1200, 1920, 1.5, true, true,
      _androidTabletUA('KFTRWI', '11'));

  // ── Laptops ──────────────────────────────────────────────
  add('macbook-air-13', 1470, 956, 2.0, false, false, _safariMac);
  add('macbook-air-15', 1710, 1112, 2.0, false, false, _safariMac);
  add('macbook-pro-14', 1512, 982, 2.0, false, false, _safariMac);
  add('macbook-pro-16', 1728, 1117, 2.0, false, false, _safariMac);
  add('macbook-air-13-chrome', 1470, 956, 2.0, false, false, _chromeMac);
  add('macbook-pro-14-chrome', 1512, 982, 2.0, false, false, _chromeMac);
  add('macbook-pro-16-chrome', 1728, 1117, 2.0, false, false, _chromeMac);
  add('surface-laptop-5', 1504, 1004, 1.5, false, true, _edgeDesktop);
  add('surface-laptop-studio', 1536, 1024, 2.0, false, true, _edgeDesktop);
  add('dell-xps-13', 1920, 1200, 1.5, false, false, _chromeDesktop);
  add('dell-xps-15', 1920, 1200, 1.5, false, false, _chromeDesktop);
  add('dell-xps-13-4k', 3840, 2400, 2.0, false, false, _chromeDesktop);
  add('dell-xps-15-4k', 3840, 2400, 2.0, false, false, _chromeDesktop);
  add('thinkpad-x1-carbon', 1920, 1200, 1.25, false, false, _chromeDesktop);
  add('hp-spectre-x360', 1920, 1080, 1.5, false, true, _chromeDesktop);
  add('chromebook-14', 1366, 768, 1.0, false, false, _chromeDesktop);

  // ── Desktop Resolutions ──────────────────────────────────
  // Chrome
  add('desktop-1366x768', 1366, 768, 1.0, false, false, _chromeDesktop);
  add('desktop-1440x900', 1440, 900, 1.0, false, false, _chromeDesktop);
  add('desktop-1536x864', 1536, 864, 1.0, false, false, _chromeDesktop);
  add('desktop-1600x900', 1600, 900, 1.0, false, false, _chromeDesktop);
  add('desktop-1920x1080', 1920, 1080, 1.0, false, false, _chromeDesktop);
  add('desktop-2560x1440', 2560, 1440, 1.0, false, false, _chromeDesktop);
  add('desktop-3840x2160', 3840, 2160, 1.5, false, false, _chromeDesktop);
  add('desktop-1080p', 1920, 1080, 1.0, false, false, _chromeDesktop);
  add('desktop-1440p', 2560, 1440, 1.0, false, false, _chromeDesktop);
  add('desktop-4k', 3840, 2160, 1.5, false, false, _chromeDesktop);

  // Firefox
  add('desktop-1920x1080-firefox', 1920, 1080, 1.0, false, false,
      _firefoxDesktop);
  add('desktop-2560x1440-firefox', 2560, 1440, 1.0, false, false,
      _firefoxDesktop);
  add('desktop-1366x768-firefox', 1366, 768, 1.0, false, false,
      _firefoxDesktop);

  // Safari (macOS)
  add('desktop-1920x1080-safari', 1920, 1080, 2.0, false, false, _safariMac);
  add('desktop-2560x1440-safari', 2560, 1440, 2.0, false, false, _safariMac);
  add('desktop-1440x900-safari', 1440, 900, 2.0, false, false, _safariMac);

  // Edge
  add('desktop-1920x1080-edge', 1920, 1080, 1.0, false, false, _edgeDesktop);
  add('desktop-2560x1440-edge', 2560, 1440, 1.0, false, false, _edgeDesktop);

  // Firefox macOS
  add('desktop-1920x1080-firefox-mac', 1920, 1080, 2.0, false, false,
      _firefoxMac);

  // ── Legacy / Convenience Aliases (mapped later) ──────────

  return m;
}

/// Normalizes a device name for lookup:
/// "iPhone 14 Pro Max" → "iphone-14-pro-max"
/// "iphone14promax" → "iphone-14-pro-max"
/// "pixel 7" → "pixel-7"
String _normalizeDeviceName(String input) {
  // Lowercase and trim
  var s = input.trim().toLowerCase();
  // Replace spaces and underscores with hyphens
  s = s.replaceAll(RegExp(r'[\s_]+'), '-');
  // Remove duplicate hyphens
  s = s.replaceAll(RegExp(r'-+'), '-');
  // Try direct match first
  if (devicePresets.containsKey(s)) return s;

  // Insert hyphens between letters and numbers: "iphone14" → "iphone-14"
  s = s.replaceAllMapped(RegExp(r'([a-z])(\d)'), (m) => '${m[1]}-${m[2]}');
  s = s.replaceAllMapped(RegExp(r'(\d)([a-z])'), (m) => '${m[1]}-${m[2]}');
  // Remove duplicate hyphens again
  s = s.replaceAll(RegExp(r'-+'), '-');

  return s;
}

/// Common aliases that map to canonical names.
final Map<String, String> _aliases = {
  'iphone-se': 'iphone-se-3rd',
  'iphone-se-2': 'iphone-se-2nd',
  'iphone-se-1': 'iphone-se-1st',
  'ipad-pro': 'ipad-pro-12.9',
  'ipad-air': 'ipad-air-m2',
  'ipad-mini': 'ipad-mini-6th',
  'ipad': 'ipad-10th',
  'pixel': 'pixel-9',
  'galaxy-s24': 'galaxy-s24',
  'galaxy-fold': 'galaxy-z-fold-5',
  'galaxy-flip': 'galaxy-z-flip-5',
  'galaxy-tab': 'galaxy-tab-s9',
  'surface-pro': 'surface-pro-9',
  'surface-laptop': 'surface-laptop-5',
  'macbook-air': 'macbook-air-13',
  'macbook-pro': 'macbook-pro-14',
  'dell-xps': 'dell-xps-13',
  'desktop': 'desktop-1920x1080',
  'desktop-hd': 'desktop-1920x1080',
  'desktop-fhd': 'desktop-1920x1080',
  'desktop-2k': 'desktop-2560x1440',
  'desktop-qhd': 'desktop-2560x1440',
  'desktop-uhd': 'desktop-3840x2160',
  'chromebook': 'chromebook-14',
};

/// Look up a device by name, supporting aliases and fuzzy normalization.
/// Returns null if not found.
DevicePreset? lookupDevice(String name) {
  final normalized = _normalizeDeviceName(name);
  // Direct match
  if (devicePresets.containsKey(normalized)) return devicePresets[normalized];
  // Alias match
  final alias = _aliases[normalized];
  if (alias != null && devicePresets.containsKey(alias)) {
    return devicePresets[alias];
  }
  return null;
}

/// Returns a categorized list of all available device names.
Map<String, List<String>> listDevicesByCategory() {
  final categories = <String, List<String>>{
    'iPhone': [],
    'Google Pixel': [],
    'Samsung Galaxy S': [],
    'Samsung Galaxy Z': [],
    'Samsung Galaxy A': [],
    'OnePlus': [],
    'Xiaomi / Redmi / Poco': [],
    'Huawei': [],
    'Other Phones': [],
    'iPad': [],
    'Android Tablets': [],
    'Surface': [],
    'Laptops': [],
    'Desktop': [],
  };

  for (final key in devicePresets.keys) {
    if (key.startsWith('iphone')) {
      categories['iPhone']!.add(key);
    } else if (key.startsWith('pixel')) {
      categories['Google Pixel']!.add(key);
    } else if (key.startsWith('galaxy-s')) {
      categories['Samsung Galaxy S']!.add(key);
    } else if (key.startsWith('galaxy-z')) {
      categories['Samsung Galaxy Z']!.add(key);
    } else if (key.startsWith('galaxy-a')) {
      categories['Samsung Galaxy A']!.add(key);
    } else if (key.startsWith('oneplus') || key.startsWith('one-plus')) {
      categories['OnePlus']!.add(key);
    } else if (key.startsWith('xiaomi') ||
        key.startsWith('redmi') ||
        key.startsWith('poco')) {
      categories['Xiaomi / Redmi / Poco']!.add(key);
    } else if (key.startsWith('huawei')) {
      categories['Huawei']!.add(key);
    } else if (key.startsWith('ipad')) {
      categories['iPad']!.add(key);
    } else if (key.startsWith('galaxy-tab') ||
        key.startsWith('kindle') ||
        key.startsWith('fire-')) {
      categories['Android Tablets']!.add(key);
    } else if (key.startsWith('surface')) {
      categories['Surface']!.add(key);
    } else if (key.startsWith('macbook') ||
        key.startsWith('dell-') ||
        key.startsWith('thinkpad') ||
        key.startsWith('hp-') ||
        key.startsWith('chromebook')) {
      categories['Laptops']!.add(key);
    } else if (key.startsWith('desktop')) {
      categories['Desktop']!.add(key);
    } else {
      categories['Other Phones']!.add(key);
    }
  }

  // Remove empty categories
  categories.removeWhere((_, v) => v.isEmpty);
  return categories;
}
