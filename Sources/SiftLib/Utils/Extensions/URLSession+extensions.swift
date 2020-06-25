import Foundation

extension URLSession {
    public func sendSynchronous(request: URLRequest) -> (data: Data?, response: URLResponse?, error: Error?) {
        var result: (data: Data?, response: URLResponse?, error: Error?)
        
        //Semaphore for synchronous call
        let semaphore = DispatchSemaphore(value: 0)
        
        let task: URLSessionDataTask = dataTask(with: request) { (data, response, error) in
            result = (data, response, error)
            semaphore.signal()
        }
        
        task.resume()
        
        _ = semaphore.wait(timeout: .distantFuture)
        
        return result
    }
}
