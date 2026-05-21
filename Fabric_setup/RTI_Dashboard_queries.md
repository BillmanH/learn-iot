# 📊 Real-Time Intelligence Dashboard Queries for OEE

This document provides KQL (Kusto Query Language) queries for building OEE (Overall Equipment Effectiveness) dashboards in Microsoft Fabric Real-Time Intelligence based on the SpaceShip Factory Simulator telemetry.

## Overview

OEE is calculated as: **OEE = Availability × Performance × Quality**

These queries assume your MQTT telemetry is being ingested into Fabric RTI and stored in a KQL database table named **`factory_telemetry`** containing all message payloads.

### Table Schema Assumptions

The `factory_telemetry` table contains columns from all message types:
- `timestamp` - Event timestamp
- `machine_id` - Machine identifier (CNC-01, 3DP-01, WELD-01, etc.)
- `station_id` - Station identifier
- `status` - Machine status
- `part_type`, `part_id` - Part information
- `assembly_type`, `assembly_id` - Assembly information
- `cycle_time`, `last_cycle_time` - Cycle timing
- `quality` - Quality result
- `test_result`, `target_type`, `target_id`, `issues_found` - Testing data
- `progress` - 3D printer progress
- `color` - Paint color
- `event_type`, `order_id` - Order/dispatch events
- `items`, `destination`, `carrier` - Order details

> **⚠️ Important**: If you encounter errors like "Failed to resolve scalar expression named 'event_type'" or similar column errors, your table may use dynamic typing. In this case, you'll need to cast columns using `tostring()`, `todouble()`, `toint()`, or `todynamic()` before using them. See examples in the queries below that use `tostring(machine_id)`, `tostring(event_type)`, etc.

### Dynamic Schema Alternative

If your data is stored with a dynamic schema (e.g., JSON column), use this pattern:

```kql
factory_telemetry
| extend payload = todynamic(data)  // If data is in a JSON column
| extend 
    machine_id = tostring(payload.machine_id),
    event_type = tostring(payload.event_type),
    timestamp = todatetime(payload.timestamp)
// Continue with query...
```

---

## 📋 Table of Contents

1. [Setup & Data Validation](#setup--data-validation)
2. [Availability Metrics](#-availability-metrics-green)
3. [Performance Metrics](#-performance-metrics-yellow)
4. [Quality Metrics](#-quality-metrics-red)
5. [Overall OEE](#-overall-oee-calculation)
6. [Real-Time Widgets](#-real-time-widgets)
7. [Trend Analysis](#-trend-analysis)
8. [Machine-Specific Dashboards](#-machine-specific-dashboards)
9. [Chart Visual Recommendations](#-chart-visual-recommendations)

---

## Setup & Data Validation

### Verify Data Ingestion
**📊 Recommended Visual: Table**  
**Description**: Displays the latest message timestamp and total count for each machine type to verify data is flowing correctly into the RTI database.

```kql
// Check latest messages by machine type
factory_telemetry
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    isnotempty(event_type), 'Event',
    'Unknown'
)
| summarize 
    LatestMessage = arg_max(timestamp, machine_id, status, event_type),
    MessageCount = count()
    by MachineType
| order by LatestMessage desc
```

### Message Count by Type (Last Hour)
**📊 Recommended Visual: Column Chart or Bar Chart**  
**Description**: Shows the volume of messages received from each machine type in the last hour to identify communication patterns and potential issues.

```kql
// Total message volume by machine type
factory_telemetry
| where timestamp > ago(1h)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    isnotempty(event_type), 'Business Event',
    'Unknown'
)
| summarize Count = count() by MachineType
| render columnchart with (title="Message Count by Type (Last Hour)")
```

---

## 🟢 Availability Metrics (Green)

**Availability = (Operating Time / Planned Production Time) × 100**

### Overall Availability by Machine Type
**📊 Recommended Visual: Column Chart**  
**Description**: Compares the average availability percentage across different machine types over the last 24 hours, showing which equipment types are most reliable.

```kql
// Calculate availability percentage for each machine type over last 24 hours
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)  // Filter to machine telemetry only
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    TotalTime = count(),
    RunningTime = countif(status == 'running'),
    IdleTime = countif(status == 'idle'),
    DownTime = countif(status in ('faulted', 'maintenance'))
    by machine_id, MachineType
| extend 
    Availability = round(100.0 * RunningTime / TotalTime, 2),
    AvailabilityCategory = case(
        100.0 * RunningTime / TotalTime >= 90, 'Excellent',
        100.0 * RunningTime / TotalTime >= 80, 'Good',
        100.0 * RunningTime / TotalTime >= 70, 'Fair',
        'Poor'
    )
| summarize AvgAvailability = round(avg(Availability), 2) by MachineType
| render columnchart with (title="Average Availability by Machine Type", ytitle="Availability %")
```

### Availability Heatmap (All Machines)
**📊 Recommended Visual: Time Chart**  
**Description**: Visualizes availability for each individual machine over time, making it easy to spot machines with recurring downtime issues.

```kql
// Show availability for each machine over time
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    RunningTime = countif(status == 'running'),
    TotalTime = count()
    by machine_id, MachineType, bin(timestamp, 1h)
| extend Availability = round(100.0 * RunningTime / TotalTime, 1)
| project timestamp, machine_id, Availability
| render timechart with (title="Machine Availability Over Time")
```

### Downtime Analysis
**📊 Recommended Visual: Bar Chart**  
**Description**: Ranks the top 10 machines by total downtime minutes in the last 24 hours, breaking down the causes (faulted, maintenance, idle).

```kql
// Identify machines with most downtime
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where status in ('faulted', 'maintenance', 'idle')
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    DowntimeMinutes = count(),
    FaultedCount = countif(status == 'faulted'),
    MaintenanceCount = countif(status == 'maintenance'),
    IdleCount = countif(status == 'idle')
    by machine_id, MachineType
| order by DowntimeMinutes desc
| take 10
| render barchart with (title="Top 10 Machines by Downtime")
```

### Real-Time Availability Status
**📊 Recommended Visual: Table**  
**Description**: Shows the current operational status of all machines with color-coded indicators based on their most recent telemetry (last 5 minutes).

```kql
// Current status of all machines (last 5 minutes)
let recentTime = 5m;
factory_telemetry
| where timestamp > ago(recentTime)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize arg_max(timestamp, status, station_id) by machine_id, MachineType
| project 
    Machine = machine_id,
    Type = MachineType,
    Station = station_id,
    Status = status,
    LastSeen = timestamp,
    StatusIndicator = case(
        status == 'running', '🟢',
        status == 'idle', '🟡',
        status in ('faulted', 'maintenance'), '🔴',
        '⚪'
    )
| order by Type, Machine
```

---

## 🟡 Performance Metrics (Yellow)

**Performance = (Ideal Cycle Time / Actual Cycle Time) × 100**

### Performance Efficiency by Machine Type
**📊 Recommended Visual: Column Chart**  
**Description**: Compares actual cycle times against ideal targets for CNC, Welding, and Painting machines to identify performance bottlenecks.

```kql
// Compare actual vs ideal cycle times
// Define ideal cycle times (from message_structure.yaml)
let idealCycleTimes = datatable(MachineType:string, IdealCycleTime:real) [
    'CNC', 12.5,
    'Welding', 8.0,
    'Painting', 5.0
];
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend actual_cycle_time = todouble(cycle_time)
| where isnotnull(actual_cycle_time) and actual_cycle_time > 0
| join kind=inner idealCycleTimes on MachineType
| extend Performance = round(100.0 * IdealCycleTime / actual_cycle_time, 2)
| summarize 
    AvgPerformance = round(avg(Performance), 2),
    AvgCycleTime = round(avg(actual_cycle_time), 2),
    MinCycleTime = round(min(actual_cycle_time), 2),
    MaxCycleTime = round(max(actual_cycle_time), 2)
    by MachineType, IdealCycleTime
| project 
    MachineType, 
    AvgPerformance, 
    IdealCycleTime, 
    AvgCycleTime,
    PerformanceCategory = case(
        AvgPerformance >= 95, 'Excellent',
        AvgPerformance >= 85, 'Good',
        AvgPerformance >= 75, 'Fair',
        'Poor'
    )
| render columnchart with (title="Average Performance by Machine Type")
```

### Cycle Time Distribution
**📊 Recommended Visual: Column Chart (Histogram)**

```kql
// Histogram of cycle times by machine type
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend actual_cycle_time = todouble(cycle_time)
| where actual_cycle_time > 0
| summarize count() by MachineType, bin(actual_cycle_time, 1.0)
| render columnchart with (title="Cycle Time Distribution", xtitle="Cycle Time (seconds)", ytitle="Count")
```

### 3D Printer Progress Tracking
**📊 Recommended Visual: Table or Bar Chart**

```kql
// Track 3D printer progress and estimate completion
factory_telemetry
| where timestamp > ago(1h)
| where machine_id startswith '3DP-'
| where status == 'running'
| extend progress = todouble(progress)
| where isnotnull(progress)
| summarize 
    arg_max(timestamp, progress) by machine_id, part_type, part_id
| extend 
    ProgressPercent = round(progress * 100, 1),
    EstimatedCompletion = case(
        progress >= 0.9, 'Completing Soon',
        progress >= 0.5, 'In Progress',
        'Just Started'
    )
| project machine_id, part_type, part_id, ProgressPercent, EstimatedCompletion
| order by ProgressPercent desc
```

### Throughput Analysis
**📊 Recommended Visual: Time Chart or Line Chart**

```kql
// Parts produced per hour by machine type
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend progress = todouble(progress)
// Count completed parts
| where (MachineType == 'CNC' and isnotnull(part_id))
    or (MachineType == '3D Printer' and isnotnull(part_id) and isnotnull(progress) and progress >= 1.0)
    or (MachineType == 'Welding' and isnotnull(assembly_id))
    or (MachineType == 'Painting' and isnotnull(part_id))
| summarize PartsPerHour = count() by MachineType, bin(timestamp, 1h)
| render timechart with (title="Throughput (Parts per Hour)")
```

---

## 🔴 Quality Metrics (Red)

**Quality = (Good Parts / Total Parts) × 100**

### Overall Quality Rate by Machine Type
**📊 Recommended Visual: Column Chart**

```kql
// Calculate quality percentage for each machine type
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where isnotnull(quality)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    TotalParts = count(),
    GoodParts = countif(quality == 'good'),
    ScrapParts = countif(quality == 'scrap'),
    ReworkParts = countif(quality == 'rework')
    by MachineType
| extend QualityRate = round(100.0 * GoodParts / TotalParts, 2)
| project 
    MachineType, 
    QualityRate, 
    GoodParts, 
    ScrapParts, 
    ReworkParts,
    QualityCategory = case(
        QualityRate >= 95, 'Excellent',
        QualityRate >= 90, 'Good',
        QualityRate >= 85, 'Fair',
        'Poor'
    )
| render columnchart with (title="Quality Rate by Machine Type")
```

### Defect Analysis
**📊 Recommended Visual: Stacked Column Chart or Pie Chart**  
**Description**: Breaks down defects by type (scrap vs rework) and machine type to identify quality issues and prioritize corrective actions.

```kql
// Breakdown of defect types
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where quality in ('scrap', 'rework')
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize DefectCount = count() by MachineType, DefectType = quality
| render columnchart with (kind=stacked, title="Defects by Type and Machine")
```

### Testing Results Summary
**📊 Recommended Visual: Table or Column Chart**  
**Description**: Summarizes test pass/fail rates by target type (Hull, Engine, etc.) to monitor quality control effectiveness and identify problem areas.

```kql
// Test pass/fail rates and issues found
factory_telemetry
| where timestamp > ago(24h)
| where machine_id startswith 'TEST-'
| where isnotnull(test_result)
| summarize 
    TotalTests = count(),
    PassedTests = countif(test_result == 'pass'),
    FailedTests = countif(test_result == 'fail'),
    TotalIssues = sum(issues_found),
    AvgIssuesPerFailure = round(avgif(issues_found, test_result == 'fail'), 2)
    by target_type
| extend 
    PassRate = round(100.0 * PassedTests / TotalTests, 2),
    TestStatus = case(
        PassRate >= 95, '🟢 Excellent',
        PassRate >= 85, '🟡 Good',
        '🔴 Needs Attention'
    )
| project target_type, PassRate, TestStatus, PassedTests, FailedTests, TotalIssues, AvgIssuesPerFailure
```

### Quality Trend Over Time
**📊 Recommended Visual: Time Chart or Line Chart**  
**Description**: Tracks quality rate percentage over the last 24 hours by machine type to spot quality degradation trends and time-based patterns.

```kql
// Quality rate trending by hour
factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where isnotnull(quality)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    GoodParts = countif(quality == 'good'),
    TotalParts = count()
    by MachineType, bin(timestamp, 1h)
| extend QualityRate = round(100.0 * GoodParts / TotalParts, 2)
| project timestamp, MachineType, QualityRate
| render timechart with (title="Quality Rate Trend by Machine Type")
```

---

## 📈 Overall OEE Calculation

### Complete OEE by Machine Type
**📊 Recommended Visual: Column Chart or Table**  
**Description**: Calculates the complete OEE score (Availability × Performance × Quality) for each machine type to provide a comprehensive equipment effectiveness rating.

```kql
// Calculate all three OEE components and overall OEE
// Ideal cycle times
let idealCycleTimes = datatable(MachineType:string, IdealCycleTime:real) [
    'CNC', 12.5,
    'Welding', 8.0,
    'Painting', 5.0
];
// Calculate Availability
let availability = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    RunningTime = countif(status == 'running'),
    TotalTime = count()
    by MachineType
| extend Availability = round(100.0 * RunningTime / TotalTime, 2);
// Calculate Performance (for machines with cycle times)
let performance = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend actual_cycle_time = case(
    MachineType == 'CNC', todouble(cycle_time),
    MachineType == 'Welding', todouble(last_cycle_time),
    MachineType == 'Painting', todouble(cycle_time),
    todouble(0)
)
| where actual_cycle_time > 0
| join kind=inner idealCycleTimes on MachineType
| extend Performance = 100.0 * IdealCycleTime / actual_cycle_time
| summarize AvgPerformance = round(avg(Performance), 2) by MachineType;
// Calculate Quality
let quality = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where isnotnull(quality)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| summarize 
    GoodParts = countif(quality == 'good'),
    TotalParts = count()
    by MachineType
| extend Quality = round(100.0 * GoodParts / TotalParts, 2);
// Combine all metrics
availability
| join kind=leftouter performance on MachineType
| join kind=leftouter quality on MachineType
| extend 
    Performance = coalesce(AvgPerformance, 100.0),  // Default to 100% if no cycle time data
    Quality = coalesce(Quality, 100.0),  // Default to 100% if no quality data
    OEE = round((Availability / 100.0) * (coalesce(AvgPerformance, 100.0) / 100.0) * (coalesce(Quality, 100.0) / 100.0) * 100.0, 2)
| project 
    MachineType, 
    OEE, 
    Availability, 
    Performance, 
    Quality,
    OEECategory = case(
        OEE >= 85, '🟢 World Class',
        OEE >= 60, '🟡 Acceptable',
        '🔴 Needs Improvement'
    )
| order by OEE desc
```

### OEE Scorecard (Single Value)
**📊 Recommended Visual: Card (Single Value)**  
**Description**: Displays the overall factory-wide OEE percentage as a single metric for high-level performance monitoring at a glance.

```kql
// Overall factory OEE score
let idealCycleTimes = datatable(MachineType:string, IdealCycleTime:real) [
    'CNC', 12.5,
    'Welding', 8.0,
    'Painting', 5.0
];
let availability = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where machine_id startswith 'CNC-' or machine_id startswith 'WELD-' or machine_id startswith 'PAINT-'
| summarize RunningTime = countif(status == 'running'), TotalTime = count()
| extend Availability = 100.0 * RunningTime / TotalTime
| summarize AvgAvailability = avg(Availability);
let performance = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend actual_cycle_time = case(
    MachineType == 'CNC', todouble(cycle_time),
    MachineType == 'Welding', todouble(last_cycle_time),
    MachineType == 'Painting', todouble(cycle_time),
    todouble(0)
)
| where actual_cycle_time > 0
| join kind=inner idealCycleTimes on MachineType
| extend Performance = 100.0 * IdealCycleTime / actual_cycle_time
| summarize AvgPerformance = avg(Performance);
let quality = factory_telemetry
| where timestamp > ago(24h)
| where isnotempty(machine_id)
| where machine_id startswith 'CNC-' or machine_id startswith 'WELD-' or machine_id startswith 'PAINT-'
| where isnotnull(quality)
| summarize GoodParts = countif(quality == 'good'), TotalParts = count()
| extend Quality = 100.0 * GoodParts / TotalParts;
availability
| extend dummy = 1
| join kind=inner (performance | extend dummy = 1) on dummy
| join kind=inner (quality | extend dummy = 1) on dummy
| extend OEE = round((AvgAvailability / 100.0) * (AvgPerformance / 100.0) * (Quality / 100.0) * 100.0, 2)
| project OEE, Availability = round(AvgAvailability, 2), Performance = round(AvgPerformance, 2), Quality = round(Quality, 2)
```

---

## 🔄 Real-Time Widgets

### Live Factory Status Board
**📊 Recommended Visual: Table or Stacked Bar Chart**  
**Description**: Provides a real-time snapshot of all machine statuses (running/idle/faulted) by type, refreshing every 30 seconds for live operational monitoring.

```kql
// Current status of entire factory (refreshes every 10 seconds)
let recentTime = 30s;
factory_telemetry
| where timestamp > ago(recentTime)
| where isnotempty(machine_id)
| extend Type = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
| where Type != 'Unknown'
| summarize arg_max(timestamp, status) by machine_id, Type
| summarize 
    Total = count(),
    Running = countif(status == 'running'),
    Idle = countif(status == 'idle'),
    Faulted = countif(status in ('faulted', 'maintenance'))
    by Type
| extend OperationalPercent = round(100.0 * Running / Total, 1)
| project Type, Total, Running, Idle, Faulted, OperationalPercent
```

### Active Orders & Dispatch
**📊 Recommended Visual: Table**  
**Description**: Lists recent order placement and dispatch events from the last hour with event type, order ID, and shipping details for tracking fulfillment operations.

```kql
// Recent orders and dispatches
factory_telemetry
| where timestamp > ago(1h)
| where isempty(machine_id)  // Events don't have machine_id
| where isnotnull(order_id)  // But they do have order_id
| extend 
    EventType = case(
        tostring(event_type) == 'order_placed', '📥 Order Placed',
        tostring(event_type) == 'order_dispatched', '📤 Dispatched',
        tostring(event_type)
    ),
    EventId = tostring(order_id),
    Details = case(
        tostring(event_type) == 'order_placed', strcat('Items: ', array_length(todynamic(items))),
        tostring(event_type) == 'order_dispatched', strcat(tostring(destination), ' via ', tostring(carrier)),
        ''
    )
| project timestamp, EventType, EventId, Details
| order by timestamp desc
| take 20
```

### Live Message Stream
**📊 Recommended Visual: Table**  
**Description**: Shows the last 50 messages from all factory systems in chronological order, displaying timestamps, source topics, machine IDs, and event summaries for real-time activity monitoring.

```kql
// Last 50 messages across all types
factory_telemetry
| extend 
    Topic = case(
        tostring(machine_id) startswith 'CNC-', 'CNC',
        tostring(machine_id) startswith '3DP-', '3D Printer',
        tostring(machine_id) startswith 'WELD-', 'Welding',
        tostring(machine_id) startswith 'PAINT-', 'Painting',
        tostring(machine_id) startswith 'TEST-', 'Testing',
        isnotnull(order_id), 'Event',
        'Unknown'
    ),
    Event = case(
        tostring(machine_id) startswith 'CNC-', strcat('Part: ', tostring(part_type)),
        tostring(machine_id) startswith '3DP-', strcat('Progress: ', tostring(round(todouble(progress) * 100, 0)), '%'),
        tostring(machine_id) startswith 'WELD-', strcat('Assembly: ', tostring(assembly_type)),
        tostring(machine_id) startswith 'PAINT-', strcat('Color: ', tostring(color)),
        tostring(machine_id) startswith 'TEST-', strcat('Result: ', tostring(test_result)),
        isnotnull(order_id), strcat(tostring(event_type), ': ', tostring(order_id)),
        ''
    )
| order by timestamp desc
| take 50
| project timestamp, Topic, machine_id, status, Event
```

---

## 📉 Trend Analysis

### OEE Trend Over 7 Days
**📊 Recommended Visual: Time Chart or Line Chart**  
**Description**: Displays daily trends of Availability, Performance, Quality, and overall OEE over the past week to identify long-term patterns and improvement opportunities.

```kql
// Daily OEE calculation
let idealCycleTimes = datatable(MachineType:string, IdealCycleTime:real) [
    'CNC', 12.5,
    'Welding', 8.0,
    'Painting', 5.0
];
// Daily availability
let availabilityTrend = factory_telemetry
| where timestamp > ago(7d)
| where isnotempty(machine_id)
| where machine_id startswith 'CNC-' or machine_id startswith 'WELD-' or machine_id startswith 'PAINT-'
| summarize 
    RunningTime = countif(status == 'running'),
    TotalTime = count()
    by bin(timestamp, 1d)
| extend Availability = 100.0 * RunningTime / TotalTime
| project timestamp, Availability;
// Daily performance
let performanceTrend = factory_telemetry
| where timestamp > ago(7d)
| where isnotempty(machine_id)
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    'Unknown'
)
| where MachineType != 'Unknown'
| extend actual_cycle_time = case(
    MachineType == 'CNC', todouble(cycle_time),
    MachineType == 'Welding', todouble(last_cycle_time),
    MachineType == 'Painting', todouble(cycle_time),
    todouble(0)
)
| where actual_cycle_time > 0
| join kind=inner idealCycleTimes on MachineType
| extend Performance = 100.0 * IdealCycleTime / actual_cycle_time
| summarize AvgPerformance = avg(Performance) by bin(timestamp, 1d)
| project timestamp, Performance = AvgPerformance;
// Daily quality
let qualityTrend = factory_telemetry
| where timestamp > ago(7d)
| where isnotempty(machine_id)
| where machine_id startswith 'CNC-' or machine_id startswith 'WELD-' or machine_id startswith 'PAINT-'
| where isnotnull(quality)
| summarize 
    GoodParts = countif(quality == 'good'),
    TotalParts = count()
    by bin(timestamp, 1d)
| extend Quality = 100.0 * GoodParts / TotalParts
| project timestamp, Quality;
// Combine trends
availabilityTrend
| join kind=inner performanceTrend on timestamp
| join kind=inner qualityTrend on timestamp
| extend OEE = round((Availability / 100.0) * (Performance / 100.0) * (Quality / 100.0) * 100.0, 2)
| project timestamp, OEE, Availability, Performance, Quality
| render timechart with (title="OEE Trend (7 Days)")
```

### Peak vs Off-Peak Performance
**📊 Recommended Visual: Column Chart**  
**Description**: Compares availability percentages across different work shifts (morning/afternoon/night) by machine type to identify shift-based performance differences and staffing impacts.

```kql
// Compare performance during different shifts
factory_telemetry
| where timestamp > ago(7d)
| where isnotempty(machine_id)
| where machine_id startswith 'CNC-' or machine_id startswith 'WELD-' or machine_id startswith 'PAINT-'
| extend 
    Type = case(
        machine_id startswith 'CNC-', 'CNC',
        machine_id startswith 'WELD-', 'Welding',
        machine_id startswith 'PAINT-', 'Painting',
        'Unknown'
    ),
    Hour = hourofday(timestamp),
    Shift = case(
        hourofday(timestamp) >= 6 and hourofday(timestamp) < 14, 'Morning Shift',
        hourofday(timestamp) >= 14 and hourofday(timestamp) < 22, 'Afternoon Shift',
        'Night Shift'
    )
| where Type != 'Unknown'
| summarize 
    RunningTime = countif(status == 'running'),
    TotalTime = count()
    by Shift, Type
| extend Availability = round(100.0 * RunningTime / TotalTime, 2)
| project Shift, Type, Availability
| render columnchart with (kind=unstacked, title="Availability by Shift")
```

---

## 🔧 Machine-Specific Dashboards

### CNC Machine Deep Dive
**📊 Recommended Visual: Table**  
**Description**: Provides detailed performance metrics for a specific CNC machine including cycle times, availability, quality rate, and part types produced over the last 24 hours for granular diagnostics.

```kql
// Detailed CNC analysis
let machineId = 'CNC-01';  // Change to specific machine
factory_telemetry
| where timestamp > ago(24h)
| where machine_id == machineId
| summarize 
    TotalCycles = count(),
    RunningCycles = countif(status == 'running'),
    AvgCycleTime = round(avg(cycle_time), 2),
    MinCycleTime = round(min(cycle_time), 2),
    MaxCycleTime = round(max(cycle_time), 2),
    GoodParts = countif(quality == 'good'),
    ScrapParts = countif(quality == 'scrap'),
    PartTypes = make_set(part_type)
| extend 
    Availability = round(100.0 * RunningCycles / TotalCycles, 2),
    QualityRate = round(100.0 * GoodParts / (GoodParts + ScrapParts), 2)
| project 
    Machine = machineId,
    Availability,
    QualityRate,
    AvgCycleTime,
    MinCycleTime,
    MaxCycleTime,
    GoodParts,
    ScrapParts,
    PartTypes
```

### Testing Rig Analysis
**📊 Recommended Visual: Column Chart**  
**Description**: Analyzes test failure patterns by target type and testing machine over the last 7 days, showing failure counts and average issues per failure to pinpoint recurring quality problems.

```kql
// Test failure patterns
factory_telemetry
| where timestamp > ago(7d)
| where machine_id startswith 'TEST-'
| where test_result == 'fail'
| summarize 
    FailureCount = count(),
    TotalIssues = sum(issues_found),
    AvgIssues = round(avg(issues_found), 2)
    by target_type, machine_id
| order by FailureCount desc
| render columnchart with (title="Test Failures by Target Type and Machine")
```

---

## � Chart Visual Recommendations Summary

This section provides a quick reference for which chart type works best for each query in Microsoft Fabric Real-Time Intelligence.

### Setup & Verification Queries

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Verify Data Ingestion | Table | Best for viewing raw sample records |
| Message Count by Type | Column Chart or Bar Chart | Compare categorical counts side-by-side |

### Availability Metrics (Green)

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Overall Availability by Machine Type | Column Chart | Compare percentages across categories |
| Availability Trend Over Time | Time Chart or Line Chart | Show trends with timestamp on X-axis |
| Downtime Analysis | Bar Chart | Rank machines by downtime duration |
| Real-Time Availability Status | Table | Display detailed status with multiple columns |

### Performance Metrics (Yellow)

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Performance Efficiency by Machine Type | Column Chart | Compare performance percentages |
| Cycle Time Distribution | Column Chart (Histogram) | Show frequency distribution |
| 3D Printer Progress Tracking | Table or Bar Chart | Show progress % per machine |
| Throughput Analysis | Time Chart or Line Chart | Track production rate over time |

### Quality Metrics (Red)

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Overall Quality Rate by Machine Type | Column Chart | Compare quality percentages |
| Defect Analysis | Stacked Column Chart or Pie Chart | Show composition of defect types |
| Testing Results Summary | Table or Column Chart | Display pass/fail metrics |
| Quality Trend Over Time | Time Chart or Line Chart | Track quality changes over time |

### OEE Calculation

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Complete OEE by Machine Type | Column Chart or Table | Compare overall OEE scores |
| OEE Scorecard | Card (Single Value) | Highlight single factory-wide metric |

### Real-Time Widgets

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| Live Factory Status Board | Table or Stacked Bar Chart | Show current operational status |
| Active Orders & Dispatch | Table | Display recent events with details |
| Live Message Stream | Table | Show recent messages chronologically |

### Trend Analysis

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| OEE Trend Over 7 Days | Time Chart or Line Chart | Track multi-metric trends over time |
| Peak vs Off-Peak Performance | Column Chart | Compare performance across shifts |

### Machine-Specific Dashboards

| Query | Recommended Visual | Rationale |
|-------|-------------------|-----------|
| CNC Machine Deep Dive | Table | Display comprehensive machine statistics |
| Testing Rig Analysis | Column Chart | Compare failure counts by target type |

### Available Chart Types in Microsoft Fabric RTI

Fabric Real-Time Intelligence supports these visualization types:

1. **Table** - Multi-column data with sorting/filtering
2. **Card (Single Value)** - Single KPI metric
3. **Column Chart** - Vertical bars for categorical comparisons
4. **Bar Chart** - Horizontal bars, good for rankings
5. **Line Chart** - Continuous data with trends
6. **Time Chart** - Specialized line chart for time-series data
7. **Pie Chart** - Part-to-whole relationships (use sparingly)
8. **Stacked Column/Bar Chart** - Show composition within categories
9. **Area Chart** - Like line chart with filled area below

### Chart Selection Guidelines

- **Use Tables** when you need to show multiple columns of detailed data, or when values need precise reading
- **Use Column/Bar Charts** for comparing values across categories (Bar Chart works better with long category names)
- **Use Time Charts/Line Charts** for showing trends over time (Time Chart is optimized for timestamp-based data)
- **Use Cards** for single important KPIs that need maximum visibility (e.g., overall factory OEE)
- **Use Stacked Charts** to show both total and composition (e.g., defects by type)
- **Avoid Pie Charts** for more than 5-6 categories or when precise comparison is needed

---

## �💡 Dashboard Design Tips

### Recommended Layout

1. **Top Row**: KPI Cards
   - Overall OEE (single value)
   - Availability % (single value with trend)
   - Performance % (single value with trend)
   - Quality % (single value with trend)

2. **Second Row**: Real-Time Status
   - Live Factory Status Board
   - Active Machines Map
   - Recent Alerts

3. **Third Row**: Trends
   - OEE Trend (last 24 hours)
   - Quality Trend by Machine Type
   - Throughput Chart

4. **Bottom Row**: Details
   - Machine-specific tables
   - Defect analysis
   - Order/Dispatch feed

### Refresh Intervals

- **Real-time widgets**: 10-30 seconds
- **Trend charts**: 1-5 minutes
- **Summary tables**: 5-15 minutes
- **Historical analysis**: Manual refresh

### Alert Thresholds

```kql
// Example: Machines below acceptable OEE
let oeeThreshold = 60.0;
// [Insert OEE calculation query here]
| where OEE < oeeThreshold
| project MachineType, OEE, Alert = '⚠️ Below Threshold'
```

---

## 📚 Additional Resources

- **Table Name**: All queries use `factory_telemetry` - adjust if your table name differs
- **Time Ranges**: Customize `ago()` values for your needs
- **Binning**: Adjust `bin()` sizes for appropriate granularity
- **Filters**: Add `where` clauses for specific stations, shifts, or date ranges

### Identifying Machine Types

All queries use the pattern:
```kql
| extend MachineType = case(
    machine_id startswith 'CNC-', 'CNC',
    machine_id startswith '3DP-', '3D Printer',
    machine_id startswith 'WELD-', 'Welding',
    machine_id startswith 'PAINT-', 'Painting',
    machine_id startswith 'TEST-', 'Testing',
    'Unknown'
)
```

### Handling Cycle Time Fields

All machine types that report cycle time use the `cycle_time` column:
- **CNC**: `cycle_time` (time to complete machining)
- **Welding**: `cycle_time` (maps from JSON field `last_cycle_time`)
- **Painting**: `cycle_time` (time to complete painting)

Simply use `cycle_time` directly:
```kql
| extend actual_cycle_time = todouble(cycle_time)
| where isnotnull(actual_cycle_time) and actual_cycle_time > 0
```

## 🔗 Query Variables

Create parameters in your RTI dashboard for dynamic filtering:

```kql
// Use dashboard parameters
let SelectedMachineType = dynamic(['CNC', '3D Printer']);  // From dropdown
let TimeRange = 24h;  // From time picker
let MinOEE = 60.0;  // From slider
let SelectedMachineId = 'CNC-01';  // From machine selector

// Example usage
factory_telemetry
| where timestamp > ago(TimeRange)
| where machine_id startswith SelectedMachineType
| where machine_id == SelectedMachineId or SelectedMachineId == 'All'
```

---

**Last Updated**: October 30, 2025  
**Version**: 1.0  
**For**: SpaceShip Factory Simulator + Microsoft Fabric RTI
