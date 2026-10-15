//
//  RoomyLimits.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS

/// Output limits with far more time than an agent gets, so a busy machine does not stop a command
/// whose test is about something else.
let roomyLimits = OutputLimits(timeLimit: .seconds(120))
