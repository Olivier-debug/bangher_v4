// ignore_for_file: unused_import
// Import files that register CacheWiper hooks via top-level initializers.

import 'cache/peer_profile_cache.dart';        // registers PeerProfileCache hook
import 'cache/pinned_image_cache.dart';        // registers PinnedImageCache hook (your earlier file)
import '../features/profile/pages/create_or_complete_profile_page.dart';
// ^ pulls in the SignedUrlCache hook we just added
