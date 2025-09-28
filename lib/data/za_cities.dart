// FILE: lib/data/za_cities.dart
// Minimal, accurate city + coords set for South Africa (extendable).
// WHY: Offline-first fallback for manual selection.

import 'package:flutter/foundation.dart';

@immutable
class ZaCity {
  final String name;
  final String province;
  final double lat;
  final double lon;
  const ZaCity({
    required this.name,
    required this.province,
    required this.lat,
    required this.lon,
  });
}

const List<ZaCity> zaCities = [
  // Gauteng
  ZaCity(name: 'Johannesburg', province: 'Gauteng', lat: -26.2041, lon: 28.0473),
  ZaCity(name: 'Pretoria', province: 'Gauteng', lat: -25.7479, lon: 28.2293),
  ZaCity(name: 'Soweto', province: 'Gauteng', lat: -26.2678, lon: 27.8585),
  ZaCity(name: 'Sandton', province: 'Gauteng', lat: -26.1076, lon: 28.0567),
  ZaCity(name: 'Midrand', province: 'Gauteng', lat: -25.9992, lon: 28.1269),
  ZaCity(name: 'Centurion', province: 'Gauteng', lat: -25.8600, lon: 28.1890),
  ZaCity(name: 'Kempton Park', province: 'Gauteng', lat: -26.1006, lon: 28.2294),
  ZaCity(name: 'Tembisa', province: 'Gauteng', lat: -25.9950, lon: 28.2268),
  ZaCity(name: 'Benoni', province: 'Gauteng', lat: -26.1900, lon: 28.3200),
  ZaCity(name: 'Boksburg', province: 'Gauteng', lat: -26.2140, lon: 28.2596),
  ZaCity(name: 'Brakpan', province: 'Gauteng', lat: -26.2366, lon: 28.3694),
  ZaCity(name: 'Krugersdorp', province: 'Gauteng', lat: -26.0850, lon: 27.7667),
  ZaCity(name: 'Randburg', province: 'Gauteng', lat: -26.0961, lon: 27.9721),
  ZaCity(name: 'Roodepoort', province: 'Gauteng', lat: -26.1625, lon: 27.8725),
  ZaCity(name: 'Vereeniging', province: 'Gauteng', lat: -26.6731, lon: 27.9319),
  ZaCity(name: 'Vanderbijlpark', province: 'Gauteng', lat: -26.7096, lon: 27.8559),

  // Western Cape
  ZaCity(name: 'Cape Town', province: 'Western Cape', lat: -33.9249, lon: 18.4241),
  ZaCity(name: 'Stellenbosch', province: 'Western Cape', lat: -33.9344, lon: 18.8610),
  ZaCity(name: 'Paarl', province: 'Western Cape', lat: -33.7342, lon: 18.9621),
  ZaCity(name: 'Worcester', province: 'Western Cape', lat: -33.6460, lon: 19.4485),
  ZaCity(name: 'George', province: 'Western Cape', lat: -33.9648, lon: 22.4590),
  ZaCity(name: 'Mossel Bay', province: 'Western Cape', lat: -34.1831, lon: 22.1460),
  ZaCity(name: 'Knysna', province: 'Western Cape', lat: -34.0363, lon: 23.0473),
  ZaCity(name: 'Somerset West', province: 'Western Cape', lat: -34.0794, lon: 18.8569),
  ZaCity(name: 'Khayelitsha', province: 'Western Cape', lat: -34.0406, lon: 18.6766),

  // KwaZulu-Natal
  ZaCity(name: 'Durban', province: 'KwaZulu-Natal', lat: -29.8587, lon: 31.0218),
  ZaCity(name: 'Pietermaritzburg', province: 'KwaZulu-Natal', lat: -29.6006, lon: 30.3794),
  ZaCity(name: 'Richards Bay', province: 'KwaZulu-Natal', lat: -28.7807, lon: 32.0383),
  ZaCity(name: 'Newcastle', province: 'KwaZulu-Natal', lat: -27.7577, lon: 29.9318),
  ZaCity(name: 'Umlazi', province: 'KwaZulu-Natal', lat: -29.9700, lon: 30.8850),
  ZaCity(name: 'Ballito', province: 'KwaZulu-Natal', lat: -29.5380, lon: 31.2140),

  // Eastern Cape
  ZaCity(name: 'Gqeberha (Port Elizabeth)', province: 'Eastern Cape', lat: -33.9608, lon: 25.6022),
  ZaCity(name: 'East London', province: 'Eastern Cape', lat: -33.0153, lon: 27.9116),
  ZaCity(name: 'Mthatha', province: 'Eastern Cape', lat: -31.5889, lon: 28.7844),
  ZaCity(name: 'Queenstown (Komani)', province: 'Eastern Cape', lat: -31.8976, lon: 26.8753),
  ZaCity(name: 'Grahamstown (Makhanda)', province: 'Eastern Cape', lat: -33.3102, lon: 26.5328),
  ZaCity(name: 'Uitenhage (Kariega)', province: 'Eastern Cape', lat: -33.7648, lon: 25.3971),
  ZaCity(name: 'Jeffreys Bay', province: 'Eastern Cape', lat: -34.0500, lon: 24.9167),

  // Free State
  ZaCity(name: 'Bloemfontein', province: 'Free State', lat: -29.0852, lon: 26.1596),
  ZaCity(name: 'Welkom', province: 'Free State', lat: -27.9775, lon: 26.7355),
  ZaCity(name: 'Bethlehem', province: 'Free State', lat: -28.2300, lon: 28.3069),
  ZaCity(name: 'Kroonstad', province: 'Free State', lat: -27.6500, lon: 27.2333),

  // North West
  ZaCity(name: 'Rustenburg', province: 'North West', lat: -25.6676, lon: 27.2421),
  ZaCity(name: 'Klerksdorp', province: 'North West', lat: -26.8521, lon: 26.6667),
  ZaCity(name: 'Mahikeng', province: 'North West', lat: -25.8650, lon: 25.6442),
  ZaCity(name: 'Potchefstroom', province: 'North West', lat: -26.7153, lon: 27.1030),

  // Limpopo
  ZaCity(name: 'Polokwane', province: 'Limpopo', lat: -23.9045, lon: 29.4689),
  ZaCity(name: 'Thohoyandou', province: 'Limpopo', lat: -22.9456, lon: 30.4854),
  ZaCity(name: 'Tzaneen', province: 'Limpopo', lat: -23.8333, lon: 30.1667),
  ZaCity(name: 'Mokopane', province: 'Limpopo', lat: -24.1944, lon: 29.0097),
  ZaCity(name: 'Phalaborwa', province: 'Limpopo', lat: -23.9420, lon: 31.1411),

  // Mpumalanga
  ZaCity(name: 'Mbombela (Nelspruit)', province: 'Mpumalanga', lat: -25.4658, lon: 30.9853),
  ZaCity(name: 'eMalahleni (Witbank)', province: 'Mpumalanga', lat: -25.8728, lon: 29.2553),
  ZaCity(name: 'Middelburg', province: 'Mpumalanga', lat: -25.7751, lon: 29.4648),
  ZaCity(name: 'Secunda', province: 'Mpumalanga', lat: -26.5539, lon: 29.1658),
  ZaCity(name: 'Ermelo', province: 'Mpumalanga', lat: -26.5333, lon: 29.9833),

  // Northern Cape
  ZaCity(name: 'Kimberley', province: 'Northern Cape', lat: -28.7282, lon: 24.7499),
  ZaCity(name: 'Upington', province: 'Northern Cape', lat: -28.4541, lon: 21.2561),
  ZaCity(name: 'Springbok', province: 'Northern Cape', lat: -29.6644, lon: 17.8896),

  // KwaZulu-Natal (more coastals)
  ZaCity(name: 'Port Shepstone', province: 'KwaZulu-Natal', lat: -30.7414, lon: 30.4470),
  ZaCity(name: 'Margate', province: 'KwaZulu-Natal', lat: -30.8636, lon: 30.3708),

  // Western Cape (more towns)
  ZaCity(name: 'Hermanus', province: 'Western Cape', lat: -34.4187, lon: 19.2345),
  ZaCity(name: 'Vredenburg', province: 'Western Cape', lat: -32.9070, lon: 17.9899),
  ZaCity(name: 'Beaufort West', province: 'Western Cape', lat: -32.3558, lon: 22.5820),

  // Eastern Cape (more)
  ZaCity(name: 'Queenstown East (Ezibeleni)', province: 'Eastern Cape', lat: -31.9040, lon: 26.9400),

  // Free State small
  ZaCity(name: 'Sasolburg', province: 'Free State', lat: -26.8135, lon: 27.8166),
];

