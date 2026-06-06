# P0 Streaming Spike

## AVPlayer authenticated HLS

Current backend playlists do not propagate `?token=` into child playlist, init segment, or segment URIs. Therefore Apple playback must prove one of:

1. A custom-scheme `AVAssetResourceLoaderDelegate` can fetch every HLS resource with `Authorization: Bearer <access token>`.
2. The backend is adjusted to emit tokenized child URIs for native-player use.

The scaffold includes `AuthenticatedHLSLoader` for option 1.

## tvOS capacity

Start with 4 live HLS streams, then test 6 and 9 streams on Apple TV hardware. Simulator results are not accepted for streaming capacity.

## WebRTC

iOS WebRTC remains a spike. tvOS WebRTC is deferred until a library and H.264 decode path are proven.
