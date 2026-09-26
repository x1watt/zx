// The global console streams of the SDK's console program: g_StdOut and
// g_StdErr (StdOutStream.cpp), g_StdStream and g_ErrStream (MainAr.cpp)
// and g_StdIn (StdInStream.cpp). They are set for each run of the program.

import 'std_stream.dart';

/// g_StdOut.
late StdOutStream gStdOut;

/// g_StdErr.
late StdOutStream gStdErr;

/// g_StdStream: the stream for messages (null with -bso0).
StdOutStream? gStdStream;

/// g_ErrStream: the stream for errors (null with -bse0).
StdOutStream? gErrStream;

/// g_StdIn.
late StdInStream gStdIn;

/// The IO of the current run.
late CliIo gIo;
