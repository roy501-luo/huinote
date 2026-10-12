import Foundation
import Security
import Darwin

// Stable, narrowly scoped keychain client. Never accept arbitrary service names or callers.
struct Request: Codable { var operation: String; var account: String; var value: String? }
struct Response: Codable { var status: Int32; var value: String? }
let service = "local.MeetingAssistant"
let callerRequirement = "identifier \"local.MeetingAssistant\" and certificate leaf = H\"b26476f919894124381dab0746284a36d8282de3\""
func authorizedParent() -> Bool {
 var code: SecCode?; var requirement: SecRequirement?
 guard SecRequirementCreateWithString(callerRequirement as CFString,[],&requirement) == errSecSuccess,
       SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:getppid()] as CFDictionary,[],&code) == errSecSuccess,
       let code, let requirement else { return false }
 return SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement) == errSecSuccess
}
func handle(_ request: Request) -> Response {
 guard ["asr","llm"].contains(request.account), ["read","save","probe"].contains(request.operation) else { return Response(status:errSecParam) }
 var query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:request.account]
 if request.operation == "read" || request.operation == "probe" {
  if request.operation == "probe" { SecKeychainSetUserInteractionAllowed(false) }
  query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary,&result)
  if status == errSecItemNotFound { return Response(status:status) }
  guard status == errSecSuccess, let data = result as? Data else { return Response(status:status == errSecSuccess ? errSecDecode : status) }
  return Response(status:status,value:request.operation == "probe" ? nil : String(decoding:data,as:UTF8.self))
 }
 guard let value = request.value, value.utf8.count <= 16384 else { return Response(status:errSecParam) }
 if value.isEmpty {
  let status = SecItemDelete(query as CFDictionary)
  return Response(status:status == errSecItemNotFound ? errSecSuccess : status)
 }
 let data = Data(value.utf8)
 var status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
 if status == errSecItemNotFound {
  query[kSecValueData as String] = data
  status = SecItemAdd(query as CFDictionary,nil)
 }
 return Response(status:status)
}
guard authorizedParent() else { exit(77) }
// Bound input; keys only transit anonymous pipes, never command arguments or files.
let input = try FileHandle.standardInput.read(upToCount:32768) ?? Data()
let result: Response
if let request = try? JSONDecoder().decode(Request.self,from:input) { result = handle(request) }
else { result = Response(status:errSecParam) }
if let data = try? JSONEncoder().encode(result) { try? FileHandle.standardOutput.write(contentsOf:data) }
