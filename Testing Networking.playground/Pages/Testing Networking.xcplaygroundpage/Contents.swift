import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true


enum HttpMethod<Body> {
    case get
    case post(Body)
}

extension HttpMethod {
    var method: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

struct Resource<A> {
    var urlRequest: URLRequest
    let parse: (Data) -> A?
}

extension Resource {
    func map<B>(_ transform: @escaping (A) -> B) -> Resource<B> {
        return Resource<B>(urlRequest: urlRequest) { self.parse($0).map(transform) }
    }
}

extension Resource where A: Decodable {
    init(get url: URL) {
        self.urlRequest = URLRequest(url: url)
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }
    
    init<Body: Encodable>(url: URL, method: HttpMethod<Body>) {
        urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.method
        switch method {
        case .get: ()
        case .post(let body):
            self.urlRequest.httpBody = try! JSONEncoder().encode(body)
        }
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }
}

extension URLSession {
    func load<A>(_ resource: Resource<A>, completion: @escaping (A?) -> ()) {
        dataTask(with: resource.urlRequest) { data, _, _ in
            completion(data.flatMap(resource.parse))
            }.resume()
    }
}

struct Episode: Codable {
    var number: Int
    var title: String
    var collection: String
}

struct Collection: Codable {
    var title: String
    var id: String
}

let episodes = Resource<[Episode]>(get: URL(string: "https://talk.objc.io/episodes.json")!)
let collections = Resource<[Collection]>(get: URL(string: "https://talk.objc.io/collections.json")!)

struct Future<A> {
    typealias Callback = (A?) -> ()
    let run: (@escaping Callback) -> ()
}

extension Future {
    func flatMap<B>(_ transform: @escaping (A) -> Future<B>) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                guard let v = value else {
                    cb(nil); return
                }
                transform(v).run(cb)
            }
        }
    }

    func map<B>(_ transform: @escaping (A) -> B) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                cb(value.map(transform))
            }
        }
    }
    
    func compactMap<B>(_ transform: @escaping (A) -> B?) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                cb(value.flatMap(transform))
            }
        }
    }

    func zipWith<B, C>(_ other: Future<B>, _ combine: @escaping (A,B) -> C) -> Future<C> {
        return Future<C> { cb in
            let group = DispatchGroup()
            var resultA: A?
            var resultB: B?
            group.enter()
            self.run { resultA = $0; group.leave() }
            group.enter()
            other.run { resultB = $0; group.leave() }
            group.notify(queue: .global(), execute: {
                guard let x = resultA, let y = resultB else {
                    cb(nil); return
                }
                cb(combine(x, y))
            })
        }
    }
}

import AppKit

let label = NSTextField()

protocol Session {
    func load<A>(_ resource: Resource<A>, completion: @escaping (A?) -> ())
}

extension Session {
    func future<A>(_ resource: Resource<A>) -> Future<A> {
        return Future<A> { cb in
            self.load(resource, completion: cb)
        }
    }
}

extension URLSession: Session {}


struct Environment {
    let session: Session
    static var env = Environment()
    
    init(session: Session = URLSession.shared) {
        self.session = session
    }
}

struct ResourceAndResponse {
    let resource: Resource<Any>
    let response: Any?
    init<A>(_ resource: Resource<A>, response: A?) {
        self.resource = resource.map { $0 }
        self.response = response.map { $0 }
    }
}

class TestSession: Session {
    private var responses: [ResourceAndResponse]
    init(responses: [ResourceAndResponse]) {
        self.responses = responses
    }
    
    func load<A>(_ resource: Resource<A>, completion: @escaping (A?) -> ()) {
        guard let idx = responses.firstIndex(where: { $0.resource.urlRequest == resource.urlRequest }), let response = responses[idx].response as? A? else {
            fatalError("No such resource: \(resource.urlRequest.url)")
        }
        responses.remove(at: idx)
        completion(response)
    }
    
    func verify() {
        assert(responses.isEmpty)
    }
}

func displayEpisodes() {
    let future = Environment.env.session.future(collections).compactMap { $0.first }.flatMap { c in
        Environment.env.session.future(episodes).map { eps in
            eps.filter { ep in ep.collection == c.id }
        }
    }.map { $0.map { $0.title } }
    future.run { label.stringValue = $0?.joined(separator: ",") ?? "" }
}

let testSession = TestSession(responses: [
    ResourceAndResponse(collections, response: [Collection(title: "Test", id: "test")]),
    ResourceAndResponse(episodes, response: [Episode(number: 1, title: "Test", collection: "test")]),
])
let testEnv = Environment(session: testSession)

Environment.env = testEnv

displayEpisodes()
assert(label.stringValue == "Test")
testSession.verify()

