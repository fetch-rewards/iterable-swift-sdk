//
//  Created by Tapash Majumder on 8/18/20.
//  Copyright © 2020 Iterable. All rights reserved.
//

import Foundation
import UIKit


@available(iOS 10.0, *)
class IterableTaskRunner: NSObject {
    // TODO: @tqm Move to `DependencyContainer` after we remove iOS 9 support
    init(networkSession: NetworkSessionProtocol = URLSession(configuration: .default),
         persistenceContextProvider: IterablePersistenceContextProvider = CoreDataPersistenceContextProvider(),
         notificationCenter: NotificationCenterProtocol = NotificationCenter.default,
         timeInterval: TimeInterval = 1.0 * 60,
         connectivityManager: NetworkConnectivityManager = NetworkConnectivityManager()) {
        ITBInfo()
        self.networkSession = networkSession
        self.persistenceContextProvider = persistenceContextProvider
        self.notificationCenter = notificationCenter
        self.timeInterval = timeInterval
        self.connectivityManager = connectivityManager
        
        super.init()

        self.notificationCenter.addObserver(self,
                                            selector: #selector(onTaskScheduled(notification:)),
                                            name: .iterableTaskScheduled,
                                            object: nil)
        self.notificationCenter.addObserver(self,
                                       selector: #selector(onAppWillEnterForeground(notification:)),
                                       name: UIApplication.willEnterForegroundNotification,
                                       object: nil)
        self.notificationCenter.addObserver(self,
                                       selector: #selector(onAppDidEnterBackground(notification:)),
                                       name: UIApplication.didEnterBackgroundNotification,
                                       object: nil)
        self.connectivityManager.connectivityChangedCallback = { [weak self]  in self?.onConnectivityChanged(connected: $0) }
    }
    
    func start() {
        ITBInfo()
        paused = false
        run()
        connectivityManager.start()
    }
    
    func stop() {
        ITBInfo()
        paused = true
        timer?.invalidate()
        timer = nil
        connectivityManager.stop()
    }
    
    @objc
    private func onTaskScheduled(notification: Notification) {
        ITBInfo()
        if !running && !paused {
            runNow()
        }
    }
    
    @objc
    private func onAppWillEnterForeground(notification _: Notification) {
        ITBInfo()
        start()
    }
    
    @objc
    private func onAppDidEnterBackground(notification _: Notification) {
        ITBInfo()
        stop()
    }

    private func runNow() {
        timer?.invalidate()
        timer = nil
        run()
    }
    
    private func onConnectivityChanged(connected: Bool) {
        ITBInfo()
        if connected {
            if paused {
                paused = false
                if !running {
                    runNow()
                }
            }
        } else {
            if !paused {
                paused = true
            }
        }
    }
    
    private func run() {
        ITBInfo()
        guard !paused else {
            ITBInfo("Cannot run when paused")
            return
        }
        guard !running else {
            ITBInfo("Already running")
            return
        }
        
        persistenceContext.perform {
            self.processTasks().onSuccess { _ in
                ITBInfo("Done processing tasks")
                self.running = false
                self.scheduleNext()
            }
        }
    }
    
    private func scheduleNext() {
        ITBInfo()
        guard !paused else {
            ITBInfo("Paused")
            return
        }

        DispatchQueue.global().async {
            ITBInfo("Scheduling timer")
            let timer = Timer.scheduledTimer(withTimeInterval: self.timeInterval, repeats: false) { _ in
                self.run()
            }
            self.timer = timer
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()
        }
    }
    
    @discardableResult
    private func processTasks() -> Future<Void, Never> {
        ITBInfo()
        running = true
        
        /// This is a recursive function.
        /// Check whether we were stopped in the middle of running tasks
        guard !paused else {
            ITBInfo("Tasks paused before finishing processTasks()")
            return Promise<Void, Never>(value: ())
        }

        if let task = try? persistenceContext.nextTask() {
            return execute(task: task).flatMap { executionResult in
                switch executionResult {
                case .success, .failure, .error:
                    self.deleteTask(task: task)
                    return self.processTasks()
                case .processing, .retry:
                    return Promise<Void, Never>(value: ())
                }
            }
        } else {
            ITBInfo("No tasks to execute")
            return Promise<Void, Never>(value: ())
        }
    }
    
    @discardableResult
    private func execute(task: IterableTask) -> Future<TaskExecutionResult, Never> {
        ITBInfo("Executing taskId: \(task.id)")
        guard task.processing == false else {
            return Promise<TaskExecutionResult, Never>(value: .processing)
        }

        switch task.type {
        case .apiCall:
            let processor = IterableAPICallTaskProcessor(networkSession: networkSession)
            return processAPICallTask(processor: processor, task: task)
        }
    }
    
    private func processAPICallTask(processor: IterableAPICallTaskProcessor,
                                    task: IterableTask) -> Future<TaskExecutionResult, Never> {
        ITBInfo()
        let result = Promise<TaskExecutionResult, Never>()
        let processor = IterableAPICallTaskProcessor(networkSession: networkSession)
        do {
            try processor.process(task: task).onSuccess { taskResult in
                switch taskResult {
                case let .success(detail: detail):
                    ITBInfo("task: \(task.id) succeeded")
                    if let successDetail = detail as? SendRequestValue {
                        let userInfo = IterableNotificationUtil.sendRequestValueToUserInfo(successDetail, taskId: task.id)
                        self.notificationCenter.post(name: .iterableTaskFinishedWithSuccess,
                                                     object: self,
                                                     userInfo: userInfo)
                    }
                    result.resolve(with: .success)
                case let .failureWithNoRetry(detail: detail):
                    ITBInfo("task: \(task.id) failed with no retry.")
                    if let failureDetail = detail as? SendRequestError {
                        let userInfo = IterableNotificationUtil.sendRequestErrorToUserInfo(failureDetail, taskId: task.id)
                        self.notificationCenter.post(name: .iterableTaskFinishedWithNoRetry,
                                                     object: self,
                                                     userInfo: userInfo)
                    }
                    result.resolve(with: .failure)
                case let .failureWithRetry(_, detail: detail):
                    ITBInfo("task: \(task.id) processed with retry")
                    if let failureDetail = detail as? SendRequestError {
                        let userInfo = IterableNotificationUtil.sendRequestErrorToUserInfo(failureDetail, taskId: task.id)
                        self.notificationCenter.post(name: .iterableTaskFinishedWithRetry,
                                                     object: self,
                                                     userInfo: userInfo)
                    }
                    result.resolve(with: .retry)
                }
            }
        } catch let error {
            ITBError("Error proessing task: \(task.id), message: \(error.localizedDescription)")
            result.resolve(with: .error)
        }
        return result
    }
    
    deinit {
        ITBInfo()
        notificationCenter.removeObserver(self)
    }
    
    private func deleteTask(task: IterableTask) {
        do {
            try persistenceContext.delete(task: task)
            try persistenceContext.save()
        } catch let error {
            ITBError(error.localizedDescription)
        }
    }
    
    private enum TaskExecutionResult {
        case processing
        case success
        case failure
        case retry
        case error
    }
    
    private var paused = false
    private let networkSession: NetworkSessionProtocol
    private let persistenceContextProvider: IterablePersistenceContextProvider
    private let notificationCenter: NotificationCenterProtocol
    private let timeInterval: TimeInterval
    private let connectivityManager: NetworkConnectivityManager
    private var timer: Timer?
    private var running = false
    
    private lazy var persistenceContext: IterablePersistenceContext = {
        return persistenceContextProvider.newBackgroundContext()
    }()
}
