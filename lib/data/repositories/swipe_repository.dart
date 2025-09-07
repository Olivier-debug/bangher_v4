import 'package:bangher/core/models/user_profile.dart' show UserProfile;


class SwipeRepository {
final Set<String> likedIds = <String>{};
final Set<String> passedIds = <String>{};
final Set<String> superLikedIds = <String>{};


bool isMutualLike(UserProfile me, UserProfile other) {
// Placeholder for server-side check; keeps UX snappy for demo.
return other.displayName.hashCode % 7 == 0; // ~14% hit rate
}
}