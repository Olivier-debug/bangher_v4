import 'package:flutter/material.dart';


class PaywallPage extends StatelessWidget {
static const routePath = '/plus';
static const routeName = 'paywall';
const PaywallPage({super.key});


@override
Widget build(BuildContext context) {
final t = Theme.of(context).textTheme;
return Scaffold(
appBar: AppBar(title: const Text('Bangher Plus')),
body: Padding(
padding: const EdgeInsets.all(24),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text('Upgrade your experience', style: t.titleLarge),
const SizedBox(height: 8),
const Text('Unlimited likes, rewinds, and premium filters.'),
const Spacer(),
FilledButton(
onPressed: () {},
child: const Text('Continue'),
),
],
),
),
);
}
}
