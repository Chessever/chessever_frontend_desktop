class CalendarEvent {
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? location;
  final String? timeControl;
  final DateTime createdAt;
  final String? description;
  final String? imageUrl;
  final String? websiteUrl;
  final String? countryCode;
  final List<dynamic>? players;
  final String? fideEventId;
  final String? eventType;
  final String? timeControlDescription;
  final String? tournamentSystem;
  final int? numberOfRounds;
  final int? numberOfPlayers;
  final String? totalPrizeFund;
  final String? website;
  final String? email;
  final String? country;
  final String? city;
  final String? venue;
  final String? address;
  final List<dynamic>? documents;
  final List<dynamic>? arbiters;

  CalendarEvent({
    required this.name,
    this.startDate,
    this.endDate,
    this.location,
    this.timeControl,
    required this.createdAt,
    this.description,
    this.imageUrl,
    this.websiteUrl,
    this.countryCode,
    this.players,
    this.fideEventId,
    this.eventType,
    this.timeControlDescription,
    this.tournamentSystem,
    this.numberOfRounds,
    this.numberOfPlayers,
    this.totalPrizeFund,
    this.website,
    this.email,
    this.country,
    this.city,
    this.venue,
    this.address,
    this.documents,
    this.arbiters,
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
    name: json['name'] as String,
    startDate: json['start_date'] == null
        ? null
        : DateTime.parse(json['start_date'] as String),
    endDate: json['end_date'] == null
        ? null
        : DateTime.parse(json['end_date'] as String),
    location: json['location'] as String?,
    timeControl: json['time_control'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    description: json['description'] as String?,
    imageUrl: json['image_url'] as String?,
    websiteUrl: json['website_url'] as String?,
    countryCode: json['country_code'] as String?,
    players: json['players'] as List<dynamic>?,
    fideEventId: json['fide_event_id'] as String?,
    eventType:
        (json['event_type'] ?? json['type_of_event'] ?? json['type'])
            as String?,
    timeControlDescription:
        (json['time_control_description'] ?? json['time_control_desc'])
            as String?,
    tournamentSystem: (json['tournament_system'] ?? json['system']) as String?,
    numberOfRounds: _parseInt(json['number_of_rounds'] ?? json['rounds']),
    numberOfPlayers: _parseInt(
      json['number_of_players'] ?? json['players_count'],
    ),
    totalPrizeFund: (json['total_prize_fund'] ?? json['prize_fund']) as String?,
    website: (json['website'] ?? json['website_url']) as String?,
    email: (json['email'] ?? json['e_mail']) as String?,
    country: json['country'] as String?,
    city: json['city'] as String?,
    venue: json['venue'] as String?,
    address: json['address'] as String?,
    documents: json['documents'] as List<dynamic>?,
    arbiters: json['arbiters'] as List<dynamic>?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'start_date': startDate?.toIso8601String(),
    'end_date': endDate?.toIso8601String(),
    'location': location,
    'time_control': timeControl,
    'created_at': createdAt.toIso8601String(),
    'description': description,
    'image_url': imageUrl,
    'website_url': websiteUrl,
    'country_code': countryCode,
    'players': players,
    'fide_event_id': fideEventId,
    'event_type': eventType,
    'time_control_description': timeControlDescription,
    'tournament_system': tournamentSystem,
    'number_of_rounds': numberOfRounds,
    'number_of_players': numberOfPlayers,
    'total_prize_fund': totalPrizeFund,
    'website': website,
    'email': email,
    'country': country,
    'city': city,
    'venue': venue,
    'address': address,
    'documents': documents,
    'arbiters': arbiters,
  };

  @override
  String toString() =>
      'CalendarEvent($name, location:$location, timeControl:$timeControl, description:$description)';
}

int? _parseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}
