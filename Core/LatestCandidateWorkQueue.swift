import Foundation

/// One executing task plus one replaceable pending task, with no timer or
/// artificial keystroke delay. Both native lookup and V10 work use this owner.
final class LatestCandidateWorkQueue {
    private let queue: DispatchQueue
    private let lock=NSLock()
    private var pending: DispatchWorkItem?
    private var running=false
    init(label: String) {queue=DispatchQueue(label:label,qos:.userInitiated,autoreleaseFrequency:.workItem)}
    func async(execute body: @escaping () -> Void) {
        async(execute: DispatchWorkItem(block: body))
    }
    func async(execute job: DispatchWorkItem) {
        lock.lock();pending?.cancel();pending=job
        guard !running else{lock.unlock();return}
        running=true;lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let task=pending else{running=false;lock.unlock();return}
                pending=nil;lock.unlock()
                if !task.isCancelled{autoreleasepool{task.perform()}}
            }
        }
    }
}
