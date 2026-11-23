/// One interface for talking to players, whether the host phone is running
/// its own server (Local) or connected to the relay (Online).
library transport;

export 'src/transport_base.dart';
export 'src/local_transport.dart';
export 'src/online_transport.dart';
export 'src/fake_transport.dart';
