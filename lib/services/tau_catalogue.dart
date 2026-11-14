/// Issue #10: the Taxonomic Amalgamation Units (TAUs) of TB 2019-04 Table 3
/// (Licuanan et al. 2017b), which an expert tags on a transect's photos for
/// generic diversity: the number of distinct TAUs, graded A–D
/// (`station_summary.dart`, `gradeDiversity`).
///
/// A separate list from `tb_categories.dart`'s TB 2017-05 life-forms, which
/// a scoring point carries. Some codes appear in both (CB, CE, CF and CM are
/// life-forms there and "other ... corals" here; Table 3 prints Fungia under
/// CMR, the mushroom-coral life-form), so the two are never mixed: a point
/// gets a life-form code, a genus tag gets a TAU code.
///
/// Codes are exactly as printed. Two names are spelled as the genera are
/// (the bulletin's text has "Coscinarea" and "fungi ids").
class Tau {
  const Tau(this.code, this.name);

  final String code;
  final String name;

  @override
  String toString() => '$name ($code)';
}

/// Table 3, in the bulletin's order (left column, then right).
const kTaus = <String, Tau>{
  'ACAN': Tau('ACAN', 'Acanthastrea'),
  'ACB': Tau('ACB', 'Acropora branching'),
  'ACC': Tau('ACC', 'Acropora corymbose'),
  'ACD': Tau('ACD', 'Acropora digitate'),
  'ACH': Tau('ACH', 'Acropora hispidose'),
  'ACT': Tau('ACT', 'Acropora plate'),
  'ACR': Tau('ACR', 'Acropora robusta group'),
  'AST': Tau('AST', 'Astreopora'),
  'AF': Tau('AF', 'Attached fungiids'),
  'CAU': Tau('CAU', 'Caulastrea'),
  'COE': Tau('COE', 'Coeloseris'),
  'COS': Tau('COS', 'Coscinaraea'),
  'CYP': Tau('CYP', 'Cyphastrea'),
  'DIP': Tau('DIP', 'Diploastrea heliopora'),
  'ECHY': Tau('ECHY', 'Echinophyllia'),
  'ECHI': Tau('ECHI', 'Echinopora'),
  'EUP': Tau('EUP', 'Euphyllia'),
  'FAV': Tau('FAV', 'Favia'),
  'FVI': Tau('FVI', 'Favites'),
  'CMR': Tau('CMR', 'Fungia'),
  'GAL': Tau('GAL', 'Galaxea'),
  'GONIA': Tau('GONIA', 'Goniastrea'),
  'GONIO': Tau('GONIO', 'Goniopora'),
  'HEL': Tau('HEL', 'Heliopora'),
  'HYD': Tau('HYD', 'Hydnophora'),
  'ISO': Tau('ISO', 'Isopora'),
  'LEPA': Tau('LEPA', 'Leptoria'),
  'LEPS': Tau('LEPS', 'Leptoseris'),
  'LOB': Tau('LOB', 'Lobophyllia'),
  'MER': Tau('MER', 'Merulina'),
  'MILL': Tau('MILL', 'Millepora'),
  'MON': Tau('MON', 'Montastrea'),
  'MONTB': Tau('MONTB', 'Montipora branching'),
  'MONTE': Tau('MONTE', 'Montipora encrusting'),
  'MONTF': Tau('MONTF', 'Montipora foliose'),
  'MYC': Tau('MYC', 'Mycedium'),
  'CB': Tau('CB', 'Other branching corals'),
  'BUB': Tau('BUB', 'Other bubble corals'),
  'CE': Tau('CE', 'Other encrusting corals'),
  'CF': Tau('CF', 'Other foliose corals'),
  'FOT': Tau('FOT', 'Other free-living fungiids'),
  'CM': Tau('CM', 'Other massive corals'),
  'OULA': Tau('OULA', 'Oulastrea'),
  'OULO': Tau('OULO', 'Oulophyllia'),
  'OXY': Tau('OXY', 'Oxypora'),
  'PACE': Tau('PACE', 'Pachyseris encrusting'),
  'PACF': Tau('PACF', 'Pachyseris foliose'),
  'PAV': Tau('PAV', 'Pavona'),
  'PEC': Tau('PEC', 'Pectinia'),
  'PLAT': Tau('PLAT', 'Platygyra'),
  'POC': Tau('POC', 'Pocillopora'),
  'PORB': Tau('PORB', 'Porites branching'),
  'PORE': Tau('PORE', 'Porites encrusting'),
  'PORM': Tau('PORM', 'Porites massive'),
  'SER': Tau('SER', 'Seriatopora'),
  'STY': Tau('STY', 'Stylophora'),
  'SYM': Tau('SYM', 'Symphyllia'),
  'TUBI': Tau('TUBI', 'Tubipora musica'),
  'TURB': Tau('TURB', 'Turbinaria'),
};

/// What TB 2019-04 asks to record even without TAU expertise: the three
/// Porites units, the Acropora units and Heliopora ("to allow for inferences
/// on disturbance history and potential resilience"). The picker shows them
/// first.
const kPriorityTauCodes = ['PORB', 'PORE', 'PORM', 'ACB', 'ACC', 'ACD', 'ACH', 'ACT', 'ACR', 'HEL'];

bool isTauCode(String code) => kTaus.containsKey(code);

/// Throws [ArgumentError] for a code not in Table 3 -- a typo must not count
/// as a genus group.
Tau tau(String code) {
  final unit = kTaus[code];
  if (unit == null) throw ArgumentError.value(code, 'code', 'Not a TB 2019-04 TAU code');
  return unit;
}

/// The priority units, then the rest alphabetically by name.
List<Tau> tausForPicker() {
  final rest = [for (final t in kTaus.values) if (!kPriorityTauCodes.contains(t.code)) t]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [for (final c in kPriorityTauCodes) kTaus[c]!, ...rest];
}
