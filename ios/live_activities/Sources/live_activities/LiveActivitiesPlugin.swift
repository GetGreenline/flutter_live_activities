import ActivityKit
import Flutter
import UIKit
import Foundation
import CryptoKit

@available(iOS 16.1, *)
class FlutterAlertConfig {
    let _title:String
    let _body:String
    let _sound:String?
    
    init(title:String, body:String, sound:String?) {
        _title = title;
        _body = body;
        _sound = sound;
    }
    
    func getAlertConfig() -> AlertConfiguration {
        return AlertConfiguration(title: LocalizedStringResource(stringLiteral: _title), body: LocalizedStringResource(stringLiteral: _body), sound: (_sound == nil) ? .default : AlertConfiguration.AlertSound.named(_sound!));
    }
}

public class LiveActivitiesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
    private var urlSchemeSink: FlutterEventSink?
    private var appGroupId: String?
    private var urlScheme: String?
    private var sharedDefault: UserDefaults?
    private var appLifecycleLiveActivityIds = [String]()
    // Activities ended with a scheduled dismissal date leave Activity.activities
    // immediately but stay visible on the Lock Screen until the date. Retain them
    // (type-erased — stored properties can't carry @available) so a later
    // endActivity can still force-dismiss the card.
    private var scheduledDismissalActivities: [String: Any] = [:]
    private var activityEventSink: FlutterEventSink?
    private var pushToStartTokenEventSink: FlutterEventSink?
    @MainActor private var activityUpdatesTask: Task<Void, Never>?
    @MainActor private var pushToStartTokenTask: Task<Void, Never>?
    @MainActor private var activityStateTasks: [String: Task<Void, Never>] = [:]
    @MainActor private var activityTokenTasks: [String: Task<Void, Never>] = [:]
    // activityUpdates can deliver an activity before Activity.activities contains
    // it. Keep that instance for lookups and observer restarts (iOS 13 type erasure).
    @MainActor private static var observedActivities: [String: Any] = [:]
    @MainActor private var observedActivityTokens: [String: Data] = [:]
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "live_activities", binaryMessenger: registrar.messenger())
        let urlSchemeChannel = FlutterEventChannel(name: "live_activities/url_scheme", binaryMessenger: registrar.messenger())
        let activityStatusChannel = FlutterEventChannel(name: "live_activities/activity_status", binaryMessenger: registrar.messenger())
        let pushToStartTokenUpdatesChannel = FlutterEventChannel(name: "live_activities/push_to_start_token_updates", binaryMessenger: registrar.messenger())
        
        let instance = LiveActivitiesPlugin()
        
        registrar.addMethodCallDelegate(instance, channel: channel)
        urlSchemeChannel.setStreamHandler(instance)
        activityStatusChannel.setStreamHandler(instance)
        pushToStartTokenUpdatesChannel.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }
    
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        MainActor.assumeIsolated {
            urlSchemeSink = nil
            activityEventSink = nil
            pushToStartTokenEventSink = nil
            stopObservingActivities()
            stopObservingPushToStartTokens()
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        // The event channels use Flutter's default platform thread.
        MainActor.assumeIsolated {
            switch arguments as? String {
            case "urlSchemeStream":
                urlSchemeSink = events
            case "activityUpdateStream":
                activityEventSink = events
                startObservingActivities()
            case "pushToStartTokenUpdateStream":
                pushToStartTokenEventSink = events
                startObservingPushToStartTokens()
            default:
                break
            }
        }
        
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        MainActor.assumeIsolated {
            switch arguments as? String {
            case "urlSchemeStream":
                urlSchemeSink = nil
            case "activityUpdateStream":
                activityEventSink = nil
                stopObservingActivities()
            case "pushToStartTokenUpdateStream":
                pushToStartTokenEventSink = nil
                stopObservingPushToStartTokens()
            default:
                break
            }
        }
        return nil
    }
    
    private func initializationGuard(result: @escaping FlutterResult) -> Bool {
        if self.appGroupId == nil || self.sharedDefault == nil {
            result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
            return false
        }
        return true
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "restartActivityObservers" {
            MainActor.assumeIsolated {
                stopObservingActivities()
                stopObservingPushToStartTokens()
                if activityEventSink != nil {
                    startObservingActivities()
                }
                if pushToStartTokenEventSink != nil {
                    startObservingPushToStartTokens()
                }
                result(nil)
            }
            return
        }

        if (call.method == "areActivitiesSupported") {
            guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }
            result(true)
            return
        }
        
        if (call.method == "areActivitiesEnabled") {
            guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }
            
            result(ActivityAuthorizationInfo().areActivitiesEnabled)
            return
        }
        
        if (call.method == "allowsPushStart") {
            guard #available(iOS 17.2, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }
            
            // This is iOS 17.2+ so push-to-start is supported
            result(true)
            return
        }
        
        if #available(iOS 16.1, *) {
            switch call.method {
            case "init":
                guard let args = call.arguments as? [String: Any] else {
                    return
                }
                
                self.urlScheme = args["urlScheme"] as? String;
                
                if let appGroupId = args["appGroupId"] as? String,
                   let sharedDefault = UserDefaults(suiteName: appGroupId) {
                    self.appGroupId = appGroupId
                    self.sharedDefault = sharedDefault
                    result(nil)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'appGroupId' is valid", details: nil))
                }
                
                break
            case "createActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                
                if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String? ?? nil {
                    let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
                    let enableRemoteUpdates = args["enableRemoteUpdates"] as? Bool ?? true
                    let staleIn = args["staleIn"] as? Int? ?? nil
                    let relevanceScore = args["relevanceScore"] as? Double
                    createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, relevanceScore: relevanceScore, activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data' is valid", details: nil))
                }
                break
            case "updateActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String, let data = args["data"] as? [String: Any] {
                    let alertConfigMap = args["alertConfig"] as? [String:String?];
                    let alertTitle = alertConfigMap?["title"] as? String;
                    let alertBody = alertConfigMap?["body"] as? String;
                    let alertSound = alertConfigMap?["sound"] as? String;
                    
                    let alertConfig = (alertTitle == nil || alertBody == nil) ? nil : FlutterAlertConfig(title: alertTitle!, body: alertBody!, sound: alertSound);
                    
                    let staleIn = args["staleIn"] as? Int? ?? nil
                    let relevanceScore = args["relevanceScore"] as? Double
                    
                    updateActivity(activityId: activityId, data: data, alertConfig: alertConfig, staleIn: staleIn, relevanceScore: relevanceScore, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId', 'data' are valid", details: nil))
                }
                break
            case "endActivity":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String {
                    endActivity(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "scheduleEnd":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String,
                   let endTimestamp = (args["endTimestamp"] as? NSNumber)?.doubleValue {
                    scheduleEnd(activityId: activityId, endTimestampMs: endTimestamp, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' and 'endTimestamp' are valid", details: nil))
                }
                break
            case "getActivityState":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String {
                    getActivityState(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "getPushToken":
                guard let args = call.arguments  as? [String: Any] else {
                    return
                }
                if let activityId = args["activityId"] as? String {
                    getPushToken(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "getAllActivitiesIds":
                getAllActivitiesIds(result: result)
                break
            case "getAllActivities":
                getAllActivities(result: result)
                break
            case "endAllActivities":
                endAllActivities(result: result)
                break
            case "createOrUpdateActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                
                if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String {
                    let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
                    let enableRemoteUpdates = args["enableRemoteUpdates"] as? Bool ?? true
                    let staleIn = args["staleIn"] as? Int? ?? nil
                    let relevanceScore = args["relevanceScore"] as? Double
                    createOrUpdateActivity(data: data, activityId: activityId, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, relevanceScore: relevanceScore, result: result,)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data', 'activityId' is valid", details: nil))
                }
                break
            default:
                break
            }
        } else {
            result(FlutterError(code: "WRONG_IOS_VERSION", message: "this version of iOS is not supported", details: nil))
        }
    }
    
    @available(iOS 16.1, *)
    func createActivity(data: [String: Any], removeWhenAppIsKilled: Bool, enableRemoteUpdates: Bool, staleIn: Int?, relevanceScore: Double?, activityId: String? = nil, result: @escaping FlutterResult) {
        guard let appGroupId = self.appGroupId,
              let sharedDefault = self.sharedDefault else {
            result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
            return
        }

        let liveDeliveryAttributes: LiveActivitiesAppAttributes
        if let activityId = activityId {
            let uuid = uuid5(name: activityId)
            liveDeliveryAttributes = LiveActivitiesAppAttributes(id: uuid)
        } else {
            liveDeliveryAttributes = LiveActivitiesAppAttributes()
        }
        let initialContentState = LiveActivitiesAppAttributes.LiveDeliveryData(appGroupId: appGroupId, updateId: Date().timeIntervalSince1970)
        var deliveryActivity: Activity<LiveActivitiesAppAttributes>?
        let prefix = liveDeliveryAttributes.id
        
        for item in data {
            sharedDefault.set(item.value, forKey: "\(prefix)_\(item.key)")
        }
        
        if #available(iOS 16.2, *){
            let activityContent = ActivityContent(
                state: initialContentState,
                staleDate: staleIn != nil ? Calendar.current.date(byAdding: .minute, value: staleIn!, to: Date.now) : nil,
                relevanceScore: relevanceScore ?? 0.0)
            do {
                deliveryActivity = try Activity.request(
                    attributes: liveDeliveryAttributes,
                    content: activityContent,
                    pushType: enableRemoteUpdates ? .token : nil)
            } catch (let error) {
                result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
            }
        } else {
            do {
                deliveryActivity = try Activity<LiveActivitiesAppAttributes>.request(
                    attributes: liveDeliveryAttributes,
                    contentState: initialContentState,
                    pushType: enableRemoteUpdates ? .token : nil)
                
            } catch (let error) {
                result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
            }
        }
        if (deliveryActivity != nil) {
            if removeWhenAppIsKilled {
                appLifecycleLiveActivityIds.append(deliveryActivity!.id)
            }
            Task { @MainActor in
                self.attachObserversIfNeeded(deliveryActivity!)
            }
            result(deliveryActivity!.id)
        }
    }
    
    @available(iOS 16.1, *)
    func updateActivity(activityId: String, data: [String: Any?], alertConfig: FlutterAlertConfig?, staleIn: Int?, relevanceScore: Double?, result: @escaping FlutterResult) {
        Task {
            guard let appGroupId = self.appGroupId,
                  let sharedDefault = self.sharedDefault else {
                result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
                return
            }

            let activities = await MainActor.run { Self.knownActivities() }
            guard let activity = activities.first(where: { $0.id == activityId }) else {
                result(FlutterError(code: "ACTIVITY_ERROR", message: "Activity not found", details: nil))
                return
            }
            
            let prefix = activity.attributes.id
            
            await MainActor.run {
                for (key, value) in data {
                    if let value = value, !(value is NSNull) {
                        sharedDefault.set(value, forKey: "\(prefix)_\(key)")
                    } else {
                        sharedDefault.removeObject(forKey: "\(prefix)_\(key)")
                    }
                }
            }
            
            let updatedStatus = LiveActivitiesAppAttributes.LiveDeliveryData(appGroupId: appGroupId, updateId: Date().timeIntervalSince1970)
            if #available(iOS 16.2, *) {
                let currentContent = activity.content
                let activityContent = ActivityContent(
                    state: updatedStatus,
                    staleDate: staleIn != nil ? Calendar.current.date(byAdding: .minute, value: staleIn!, to: Date.now) : currentContent.staleDate,
                    relevanceScore: relevanceScore ?? currentContent.relevanceScore)
                await activity.update(activityContent, alertConfiguration: alertConfig?.getAlertConfig())
            } else {
                await activity.update(using: updatedStatus, alertConfiguration: alertConfig?.getAlertConfig())
            }
            
            result(nil)
        }
    }
    
    @available(iOS 16.1, *)
    func createOrUpdateActivity(data: [String: Any], activityId: String, removeWhenAppIsKilled: Bool, enableRemoteUpdates: Bool, staleIn: Int?, relevanceScore: Double?, result: @escaping FlutterResult) {
        Task {
            let uuid = uuid5(name: activityId)
            
            var activities: [Activity<LiveActivitiesAppAttributes>] = []
            for _ in 0..<3 { // Try up to 3 times
                activities = await MainActor.run { Self.knownActivities() }
                if !activities.isEmpty {
                    break
                }
                try? await Task.sleep(for: .seconds(0.1))
            }
            
            let existingActivity = activities.first {
                $0.attributes.id == uuid && $0.activityState != .dismissed && $0.activityState != .ended
            }
            
            if let activityId = existingActivity?.id {
                updateActivity(activityId: activityId, data: data, alertConfig: nil, staleIn: staleIn, relevanceScore: relevanceScore, result: result)
            } else {
                createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, relevanceScore: relevanceScore, activityId: activityId, result: result)
            }
        }
    }
    
    @available(iOS 16.1, *)
    func getActivityState(activityId: String, result: @escaping FlutterResult) {
        Task { @MainActor in
            let customId = uuid5(name: activityId)
            let matchingActivity = Self.knownActivities().first {
                $0.id == activityId ||
                $0.attributes.id == customId ||
                $0.attributes.id.uuidString.uppercased() == activityId.uppercased()
            }
            
            guard let activity = matchingActivity else {
                result(nil)
                return
            }
            
            let state = activityStateToString(activityState: activity.activityState)
            result(state)
        }
    }
    
    /// Returns the attributes UUID for an ActivityKit activity identifier.
    /// Keeps native lookups on the same attributes type as the plugin's observers.
    @available(iOS 16.1, *)
    @MainActor public static func activityAttributesId(for activityId: String) -> String? {
        knownActivities()
            .first { $0.id == activityId }?
            .attributes.id.uuidString
    }

    @available(iOS 16.1, *)
    @MainActor private static func knownActivities() -> [Activity<LiveActivitiesAppAttributes>] {
        var activities = Dictionary(
            Activity<LiveActivitiesAppAttributes>.activities.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for (id, value) in observedActivities {
            if let activity = value as? Activity<LiveActivitiesAppAttributes> {
                activities[id] = activity
            }
        }
        return Array(activities.values)
    }

    @available(iOS 16.1, *)
    func getPushToken(activityId: String, result: @escaping FlutterResult) {
        Task { @MainActor in
            guard let activity = Self.knownActivities().first(where: { $0.id == activityId }),
                  activity.activityState != .ended && activity.activityState != .dismissed else {
                result(nil)
                return
            }
            let data = activity.pushToken ?? observedActivityTokens[activityId]
            result(data?.map { String(format: "%02x", $0) }.joined())
        }
    }
    
    @available(iOS 16.1, *)
    func endActivity(activityId: String, result: @escaping FlutterResult) {
        appLifecycleLiveActivityIds.removeAll { $0 == activityId }
        Task {
            await endActivitiesWithId(activityIds: [activityId])
            result(nil)
        }
    }

    // Ends the activity now with ActivityKit's `dismissalPolicy: .after(date)`
    // so the SYSTEM removes it from the Lock Screen at `date` even if the app is
    // killed and no push arrives. The activity keeps showing its last content
    // (self-ticking Text(.timer) views keep counting), but it can no longer be
    // updated and — per ActivityKit ended-state semantics — leaves the Dynamic
    // Island. Note: iOS caps the post-end display window at 4 hours.
    @available(iOS 16.1, *)
    func scheduleEnd(activityId: String, endTimestampMs: Double, result: @escaping FlutterResult) {
        Task {
            let dismissalDate = Date(timeIntervalSince1970: endTimestampMs / 1000.0)
            for activity in Activity<LiveActivitiesAppAttributes>.activities {
                let customIdUuid = uuid5(name: activityId)
                if activityId == activity.id ||
                    activityId.uppercased() == activity.attributes.id.uuidString ||
                    customIdUuid == activity.attributes.id {
                    // Retain so endActivity can still force-dismiss the ended card.
                    scheduledDismissalActivities[activityId] = activity
                    await activity.end(dismissalPolicy: .after(dismissalDate))
                    break
                }
            }
            result(nil)
        }
    }

    @available(iOS 16.1, *)
    func endAllActivities(result: @escaping FlutterResult) {
        Task {
            for activity in Activity<LiveActivitiesAppAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            appLifecycleLiveActivityIds.removeAll()
            result(nil)
        }
    }
    
    @MainActor private func startObservingPushToStartTokens() {
        guard #available(iOS 17.2, *), pushToStartTokenTask == nil else { return }
        NSLog("[LiveActivities] Push-to-start observer started; current token available: %@",
              Activity<LiveActivitiesAppAttributes>.pushToStartToken == nil ? "no" : "yes")
        pushToStartTokenTask = Task { [weak self] in
            defer {
                if !Task.isCancelled { self?.pushToStartTokenTask = nil }
            }
            if let data = Activity<LiveActivitiesAppAttributes>.pushToStartToken {
                self?.emitPushToStartToken(data)
            }
            for await data in Activity<LiveActivitiesAppAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.emitPushToStartToken(data)
            }
        }
    }

    @MainActor private func emitPushToStartToken(_ data: Data) {
        guard !data.isEmpty else { return }
        NSLog("[LiveActivities] Push-to-start token emitted to Flutter")
        pushToStartTokenEventSink?(data.map { String(format: "%02x", $0) }.joined())
    }

    @MainActor private func stopObservingPushToStartTokens() {
        pushToStartTokenTask?.cancel()
        pushToStartTokenTask = nil
    }

    @MainActor private func startObservingActivities() {
        guard #available(iOS 16.1, *) else {
            return
        }

        for activity in Self.knownActivities() {
            attachObserversIfNeeded(activity)
        }

        if #available(iOS 17.2, *), activityUpdatesTask == nil {
            activityUpdatesTask = Task { [weak self] in
                defer {
                    if !Task.isCancelled { self?.activityUpdatesTask = nil }
                }
                for await activity in Activity<LiveActivitiesAppAttributes>.activityUpdates {
                    guard let self, !Task.isCancelled else { return }
                    self.attachObserversIfNeeded(activity)
                }
            }
        }
    }

    @MainActor private func stopObservingActivities() {
        activityUpdatesTask?.cancel()
        activityUpdatesTask = nil
        activityStateTasks.values.forEach { $0.cancel() }
        activityStateTasks.removeAll()
        activityTokenTasks.values.forEach { $0.cancel() }
        activityTokenTasks.removeAll()
    }
    
    @available(iOS 16.1, *)
    func getAllActivitiesIds(result: @escaping FlutterResult) {
        MainActor.assumeIsolated {
            result(Self.knownActivities().map { $0.id })
        }
    }
    
    @available(iOS 16.1, *)
    func getAllActivities(result: @escaping FlutterResult) {
        MainActor.assumeIsolated {
            var activitiesState: [String: String] = [:]
            for activity in Self.knownActivities() {
                activitiesState[activity.id] = activityStateToString(activityState: activity.activityState)
            }
            result(activitiesState)
        }
    }
    
    @available(iOS 16.1, *)
    private func endActivitiesWithId(activityIds: [String]) async {
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            for id in activityIds {
                let customIdUuid = uuid5(name: id)
                if id == activity.id ||
                    id.uppercased() == activity.attributes.id.uuidString ||
                    customIdUuid == activity.attributes.id {
                    await activity.end(dismissalPolicy: .immediate)
                    break
                }
            }
        }
        // Activities ended via scheduleEnd are no longer in Activity.activities
        // but may still be visible until their dismissal date — re-end the
        // retained reference to clear them now (e.g. the user unmuted early).
        for id in activityIds {
            if let activity = scheduledDismissalActivities.removeValue(forKey: id)
                as? Activity<LiveActivitiesAppAttributes> {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
    
    private func handleURL(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        if components?.scheme == nil || components?.scheme != urlScheme { return false }
        
        var queryResult: Dictionary<String, Any> = Dictionary()
        
        queryResult["queryItems"] = components?.queryItems?.map({ (item) -> Dictionary<String, String> in
            var queryItemResult: Dictionary<String, String> = Dictionary()
            queryItemResult["name"] = item.name
            queryItemResult["value"] = item.value
            return queryItemResult
        })
        queryResult["scheme"] = components?.scheme
        queryResult["host"] = components?.host
        queryResult["path"] = components?.path
        queryResult["url"] = components?.url?.absoluteString
        
        urlSchemeSink?.self(queryResult)
        return true
    }
    
    @objc
    public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        _ = handleURL(url)
    }
    
    public func applicationWillTerminate(_ application: UIApplication) {
        if #available(iOS 16.1, *) {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await self.endActivitiesWithId(activityIds: self.appLifecycleLiveActivityIds)
                semaphore.signal()
            }
            
            _ = semaphore.wait(timeout: .now() + 5.0)
        }
    }
    
    struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
        public typealias LiveDeliveryData = ContentState
        
        public struct ContentState: Codable, Hashable {
            var appGroupId: String?
            // Changes on every update so ActivityKit sees a state change and
            // re-renders locked/AOD surfaces (the real payload rides App Group
            // UserDefaults, which ActivityKit cannot diff).
            var updateId: Double?

            init(appGroupId: String? = nil, updateId: Double? = nil) {
                self.appGroupId = appGroupId
                self.updateId = updateId
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
                appGroupId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("appGroupId"))
                updateId = try container.decodeIfPresent(Double.self, forKey: DynamicCodingKeys("updateId"))
            }
        }
        
        var id: UUID

        init(id: UUID = UUID()) {
            self.id = id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: DynamicCodingKeys("id")) ?? UUID()
        }
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
    
    @available(iOS 16.1, *)
    @MainActor private func monitorLiveActivity<T: ActivityAttributes>(_ activity: Activity<T>) {
        guard activityStateTasks[activity.id] == nil else { return }
        activityStateTasks[activity.id] = Task { [weak self] in
            defer {
                if !Task.isCancelled { self?.activityStateTasks.removeValue(forKey: activity.id) }
            }
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                switch state {
                case .active:
                    self.attachTokenObserverIfNeeded(activity)
                case .dismissed, .ended:
                    self.handleActivityEnded(activityId: activity.id)
                    return
                case .stale:
                    self.activityEventSink?(["activityId": activity.id, "status": "stale"])
                @unknown default:
                    self.activityEventSink?(["activityId": activity.id, "status": "unknown"])
                }
            }
        }
    }
    
    @available(iOS 16.1, *)
    @MainActor private func attachObserversIfNeeded(_ activity: Activity<LiveActivitiesAppAttributes>) {
        Self.observedActivities[activity.id] = activity
        guard activityEventSink != nil else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            handleActivityEnded(activityId: activity.id)
            return
        }
        monitorLiveActivity(activity)
        switch activity.activityState {
        case .active, .stale:
            attachTokenObserverIfNeeded(activity)
        default:
            break
        }
    }

    @MainActor private func handleActivityEnded(activityId: String) {
        activityStateTasks.removeValue(forKey: activityId)?.cancel()
        activityTokenTasks.removeValue(forKey: activityId)?.cancel()
        Self.observedActivities.removeValue(forKey: activityId)
        observedActivityTokens.removeValue(forKey: activityId)
        activityEventSink?(["activityId": activityId, "status": "ended"])
    }

    @available(iOS 16.1, *)
    @MainActor private func attachTokenObserverIfNeeded<T: ActivityAttributes>(_ activity: Activity<T>) {
        guard activityTokenTasks[activity.id] == nil else { return }
        activityTokenTasks[activity.id] = Task { [weak self] in
            defer {
                if !Task.isCancelled { self?.activityTokenTasks.removeValue(forKey: activity.id) }
            }
            guard !Task.isCancelled else { return }
            var lastToken = activity.pushToken
            if let lastToken {
                self?.emitActivityToken(lastToken, activityId: activity.id)
            }
            for await token in activity.pushTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                if token == lastToken { continue }
                lastToken = token
                self.emitActivityToken(token, activityId: activity.id)
            }
        }
    }

    @MainActor private func emitActivityToken(_ data: Data, activityId: String) {
        guard !data.isEmpty else { return }
        observedActivityTokens[activityId] = data
        let token = data.map { String(format: "%02x", $0) }.joined()
        activityEventSink?(["token": token, "activityId": activityId, "status": "active"])
    }
    
    @available(iOS 16.1, *)
    private func activityStateToString(activityState: ActivityState) -> String {
        switch activityState {
        case .active:
            return "active"
        case .ended:
            return "ended"
        case .dismissed:
            return "dismissed"
        case .stale:
            return "stale"
        @unknown default:
            return "unknown"
        }
    }
    
    private func uuid5(namespace: UUID = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, name: String) -> UUID {
        // Convert namespace UUID to bytes
        var namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        
        // Append the name bytes (as UTF-8)
        let nameBytes = Data(name.utf8)
        namespaceBytes.append(nameBytes)
        
        // SHA1 hash
        let hash = Insecure.SHA1.hash(data: namespaceBytes)
        
        // Take the first 16 bytes
        var bytes = [UInt8](hash.prefix(16))
        
        // Set UUID version to 5 (0101)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        
        // Set UUID variant to RFC 4122 (10xx)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        
        // Convert bytes to UUID
        let uuid = uuid_t(bytes[0], bytes[1], bytes[2], bytes[3],
                          bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11],
                          bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid)
    }
    
}
