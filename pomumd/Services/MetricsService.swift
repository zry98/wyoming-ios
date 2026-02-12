import Darwin
import Foundation
import Metrics
import Prometheus

/// Configures Prometheus metrics collection for monitoring server performance.
struct MetricsService {
  struct Configuration {
    let prometheusRegistry: PrometheusCollectorRegistry
    let metricsCollector: MetricsCollector
  }

  static func bootstrap() -> Configuration {
    let prometheusRegistry = PrometheusCollectorRegistry()

    var metricsFactory = PrometheusMetricsFactory(registry: prometheusRegistry)
    metricsFactory.defaultDurationHistogramBuckets = [
      .milliseconds(50),
      .milliseconds(100),
      .milliseconds(250),
      .milliseconds(500),
      .seconds(1),
      .seconds(2),
      .seconds(5),
    ]

    MetricsSystem.bootstrap(metricsFactory)

    let metricsCollector = MetricsCollector()
    return Configuration(
      prometheusRegistry: prometheusRegistry,
      metricsCollector: metricsCollector
    )
  }
}

/// Collects application and hardware metrics for Prometheus export.
///
/// Tracks connections, processing times, audio bytes, CPU, memory, and thermal state.
class MetricsCollector {

  private let namespace =
    (Bundle.main.infoDictionary?["CFBundleName"] as? String
    ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
    ?? "pomumd")
    .replacingOccurrences(of: "-", with: "_")
    .replacingOccurrences(of: " ", with: "_")
    .lowercased()

  // Application metrics: connections, errors, processing times
  private let totalConnectionsCounter: Metrics.Counter
  private let activeConnectionsGauge: Metrics.Gauge
  private var activeConnectionsCount: Int = 0
  private let errorCounter: Metrics.Counter
  private let audioBytesCounter: Metrics.Counter
  private let ttsModelProcessingTimer: Metrics.Timer
  private let sttModelProcessingTimer: Metrics.Timer
  private let ttsServiceProcessingTimer: Metrics.Timer
  private let sttServiceProcessingTimer: Metrics.Timer
  private let restartCounter: Metrics.Counter
  private let networkBytesInCounter: Metrics.Counter
  private let networkBytesOutCounter: Metrics.Counter

  // Hardware metrics: CPU, memory, thermal state
  private let cpuUsageTotalGauge: Metrics.Gauge
  private let thermalStateGauge: Metrics.Gauge
  private let memoryTotalGauge: Metrics.Gauge
  private let memoryFreeGauge: Metrics.Gauge
  private let memoryAppUsedGauge: Metrics.Gauge

  #if !LITE
    // LLM metrics
    private let llmRequestsCounter: Metrics.Counter
    private let llmActiveRequestsGauge: Metrics.Gauge
    private var llmActiveRequestsCount: Int = 0
    private let llmTokensGeneratedCounter: Metrics.Counter
    private let llmPromptTokensCounter: Metrics.Counter
    private let llmGenerationTimer: Metrics.Timer
    private let llmTimeToFirstTokenTimer: Metrics.Timer
    private let llmTokensPerSecondGauge: Metrics.Gauge
    private let llmModelLoadsCounter: Metrics.Counter
    private let llmModelLoadTimer: Metrics.Timer
    private let llmToolCallsCounter: Metrics.Counter
    private let llmStreamingRequestsCounter: Metrics.Counter
    private let llmErrorsCounter: Metrics.Counter
  #endif

  init() {
    self.cpuUsageTotalGauge = Gauge(label: "\(namespace)_cpu_usage_total_percent")
    self.thermalStateGauge = Gauge(label: "\(namespace)_thermal_state")
    self.memoryTotalGauge = Gauge(label: "\(namespace)_memory_total_bytes")
    self.memoryFreeGauge = Gauge(label: "\(namespace)_memory_free_bytes")
    self.memoryAppUsedGauge = Gauge(label: "\(namespace)_memory_app_used_bytes")

    self.totalConnectionsCounter = Counter(label: "\(namespace)_connections_total")
    self.activeConnectionsGauge = Gauge(label: "\(namespace)_connections_active")
    self.errorCounter = Counter(label: "\(namespace)_connections_errors_total")
    self.audioBytesCounter = Counter(label: "\(namespace)_audio_bytes_processed_total")
    self.ttsModelProcessingTimer = Timer(
      label: "\(namespace)_model_processing_duration_milliseconds", dimensions: [("service", "tts")])
    self.sttModelProcessingTimer = Timer(
      label: "\(namespace)_model_processing_duration_milliseconds", dimensions: [("service", "stt")])
    self.ttsServiceProcessingTimer = Timer(
      label: "\(namespace)_service_processing_duration_milliseconds", dimensions: [("service", "tts")])
    self.sttServiceProcessingTimer = Timer(
      label: "\(namespace)_service_processing_duration_milliseconds", dimensions: [("service", "stt")])
    self.restartCounter = Counter(label: "\(namespace)_restarts_total")
    self.networkBytesInCounter = Counter(label: "\(namespace)_network_bytes_received_total")
    self.networkBytesOutCounter = Counter(label: "\(namespace)_network_bytes_sent_total")

    #if !LITE
      self.llmRequestsCounter = Counter(label: "\(namespace)_llm_requests_total")
      self.llmActiveRequestsGauge = Gauge(label: "\(namespace)_llm_active_requests")
      self.llmTokensGeneratedCounter = Counter(label: "\(namespace)_llm_tokens_generated_total")
      self.llmPromptTokensCounter = Counter(label: "\(namespace)_llm_prompt_tokens_total")
      self.llmGenerationTimer = Timer(label: "\(namespace)_llm_generation_duration_milliseconds")
      self.llmTimeToFirstTokenTimer = Timer(label: "\(namespace)_llm_time_to_first_token_milliseconds")
      self.llmTokensPerSecondGauge = Gauge(label: "\(namespace)_llm_tokens_per_second")
      self.llmModelLoadsCounter = Counter(label: "\(namespace)_llm_model_loads_total")
      self.llmModelLoadTimer = Timer(label: "\(namespace)_llm_model_load_duration_milliseconds")
      self.llmToolCallsCounter = Counter(label: "\(namespace)_llm_tool_calls_total")
      self.llmStreamingRequestsCounter = Counter(label: "\(namespace)_llm_streaming_requests_total")
      self.llmErrorsCounter = Counter(label: "\(namespace)_llm_errors_total")
    #endif
  }

  func recordServerRestart() {
    restartCounter.increment()
  }

  func recordConnection() {
    totalConnectionsCounter.increment()
  }

  func incrementActiveConnections() {
    activeConnectionsCount += 1
    activeConnectionsGauge.record(activeConnectionsCount)
  }

  func decrementActiveConnections() {
    activeConnectionsCount -= 1
    activeConnectionsGauge.record(activeConnectionsCount)
  }

  func recordConnectionError() {
    errorCounter.increment()
  }

  func recordModelProcessing(bytes: Int, duration: TimeInterval, serviceType: ServiceType) {
    audioBytesCounter.increment(by: bytes)
    if duration > 0 {
      let milliseconds = Int64(duration * 1000)
      switch serviceType {
      case .tts:
        ttsModelProcessingTimer.recordMilliseconds(milliseconds)
      case .stt:
        sttModelProcessingTimer.recordMilliseconds(milliseconds)
      case .info, .unknown:
        break
      }
    }
  }

  func recordServiceProcessing(duration: TimeInterval, serviceType: ServiceType) {
    if duration > 0 {
      let milliseconds = Int64(duration * 1000)
      switch serviceType {
      case .tts:
        ttsServiceProcessingTimer.recordMilliseconds(milliseconds)
      case .stt:
        sttServiceProcessingTimer.recordMilliseconds(milliseconds)
      case .info, .unknown:
        break
      }
    }
  }

  func recordNetworkTraffic(bytesIn: UInt64, bytesOut: UInt64) {
    networkBytesInCounter.increment(by: bytesIn)
    networkBytesOutCounter.increment(by: bytesOut)
  }

  func updateHardwareMetrics() {
    let snapshot = HardwareMetrics.getSnapshot()

    cpuUsageTotalGauge.record(snapshot.cpuUsageTotal)
    thermalStateGauge.record(snapshot.thermalState)
    memoryTotalGauge.record(snapshot.memoryTotal)
    memoryFreeGauge.record(snapshot.memoryFree)
    memoryAppUsedGauge.record(snapshot.memoryAppUsed)
  }

  #if !LITE
    // MARK: - LLM Metrics

    func recordLLMRequest() {
      llmRequestsCounter.increment()
      llmActiveRequestsCount += 1
      llmActiveRequestsGauge.record(llmActiveRequestsCount)
    }

    func recordLLMRequestComplete() {
      llmActiveRequestsCount -= 1
      llmActiveRequestsGauge.record(llmActiveRequestsCount)
    }

    func recordLLMTokensGenerated(_ count: Int) {
      llmTokensGeneratedCounter.increment(by: Int64(count))
    }

    func recordLLMGeneration(duration: TimeInterval) {
      if duration > 0 {
        let milliseconds = Int64(duration * 1000)
        llmGenerationTimer.recordMilliseconds(milliseconds)
      }
    }

    func recordLLMModelLoad(duration: TimeInterval) {
      llmModelLoadsCounter.increment()
      if duration > 0 {
        let milliseconds = Int64(duration * 1000)
        llmModelLoadTimer.recordMilliseconds(milliseconds)
      }
    }

    func recordLLMError() {
      llmErrorsCounter.increment()
    }

    func recordLLMPromptTokens(_ count: Int) {
      llmPromptTokensCounter.increment(by: Int64(count))
    }

    func recordLLMTimeToFirstToken(duration: TimeInterval) {
      if duration > 0 {
        let milliseconds = Int64(duration * 1000)
        llmTimeToFirstTokenTimer.recordMilliseconds(milliseconds)
      }
    }

    func recordLLMTokensPerSecond(_ tokensPerSecond: Double) {
      llmTokensPerSecondGauge.record(tokensPerSecond)
    }

    func recordLLMToolCalls(_ count: Int) {
      llmToolCallsCounter.increment(by: Int64(count))
    }

    func recordLLMStreamingRequest() {
      llmStreamingRequestsCounter.increment()
    }
  #endif
}

// MARK: - Hardware Metrics

struct HardwareMetrics {
  let cpuUsageTotal: Float32
  let thermalState: UInt8
  let memoryTotal: UInt64
  let memoryAppUsed: UInt64
  let memoryFree: UInt64

  static func getSnapshot() -> HardwareMetrics {
    let cpu = getCPUUsage()
    let thermalState = UInt8(ProcessInfo.processInfo.thermalState.rawValue)
    let memory = getMemoryInfo()

    return HardwareMetrics(
      cpuUsageTotal: cpu,
      thermalState: thermalState,
      memoryTotal: memory.total,
      memoryAppUsed: memory.appUsed,
      memoryFree: memory.free,
    )
  }

  private static func getCPUUsage() -> Float32 {
    var numCPUs: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0

    let result = host_processor_info(
      mach_host_self(),
      PROCESSOR_CPU_LOAD_INFO,
      &numCPUs,
      &cpuInfo,
      &numCPUInfo)

    guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
      return 0.0
    }

    var totalUser: UInt32 = 0
    var totalSystem: UInt32 = 0
    var totalIdle: UInt32 = 0
    var totalNice: UInt32 = 0

    for i in 0..<Int(numCPUs) {
      let offset = Int(CPU_STATE_MAX) * i
      let user = cpuInfo[offset + Int(CPU_STATE_USER)]
      let system = cpuInfo[offset + Int(CPU_STATE_SYSTEM)]
      let idle = cpuInfo[offset + Int(CPU_STATE_IDLE)]
      let nice = cpuInfo[offset + Int(CPU_STATE_NICE)]

      totalUser += UInt32(user)
      totalSystem += UInt32(system)
      totalIdle += UInt32(idle)
      totalNice += UInt32(nice)
    }

    let totalTicks = totalUser + totalSystem + totalIdle + totalNice
    let totalUsage = totalTicks > 0 ? Float32(totalUser + totalSystem + totalNice) / Float32(totalTicks) * 100.0 : 0.0

    vm_deallocate(
      mach_task_self_,
      vm_address_t(bitPattern: cpuInfo),
      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))

    return totalUsage
  }

  private static func getMemoryInfo() -> (total: UInt64, appUsed: UInt64, free: UInt64) {
    let total = ProcessInfo.processInfo.physicalMemory

    #if os(iOS)
      let free = UInt64(os_proc_available_memory())
    #else
      var statsCount = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
      var stats = vm_statistics64()
      let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(statsCount)) { intPtr in
          host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &statsCount)
        }
      }

      let free: UInt64
      if kr == KERN_SUCCESS {
        let pageSize = UInt64(Darwin.vm_kernel_page_size)
        let freePages = UInt64(stats.free_count)
        let inactivePages = UInt64(stats.inactive_count)
        free = (freePages + inactivePages) * pageSize
      } else {
        metricsLogger.error("Failed to get system memory stats: ret=\(kr)")
        free = 0
      }
    #endif

    var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    var info = task_vm_info()
    let kr2 = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &infoCount)
      }
    }
    guard kr2 == KERN_SUCCESS else {
      metricsLogger.error("Failed to get app memory usage: ret=\(kr2)")
      return (total: total, appUsed: 0, free: free)
    }

    return (total: total, appUsed: info.phys_footprint, free: free)
  }
}
