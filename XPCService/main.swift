// XPCWhatsMeowService — the one process that contains whatsmeow.
//
// Everything is in XPCWhatsMeowServiceKit; this file only starts the listener. The binary
// it builds into is GPLv3 (see NOTICE), and it is the only binary in an app that is.

import XPCWhatsMeowServiceKit

WhatsMeowServiceListener.runService()
