import AppKit
import Carbon

struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let defaults = [HotKeyBinding(keyCode: 20,modifiers: UInt32(cmdKey | shiftKey)), HotKeyBinding(keyCode: 23,modifiers: UInt32(cmdKey | shiftKey)), HotKeyBinding(keyCode: 21,modifiers: UInt32(cmdKey | shiftKey | optionKey))]
}
@MainActor final class HotKeyService {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: ((Int)->Void)?
    private(set) var failures: [Int] = []
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer -> OSStatus in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID(); GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let owner = Unmanaged<HotKeyService>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.onAction?(Int(id.id) - 1) }; return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
    }
    func register(_ bindings:[HotKeyBinding]) {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); failures=[]
        for (index,binding) in bindings.enumerated() {
            var ref:EventHotKeyRef?; let id=EventHotKeyID(signature:0x50534854,id:UInt32(index+1))
            let status=RegisterEventHotKey(binding.keyCode,binding.modifiers,id,GetApplicationEventTarget(),0,&ref)
            if status == noErr, let ref {refs.append(ref)} else {failures.append(index)}
        }
    }
    func invalidate(){refs.forEach {UnregisterEventHotKey($0)};refs=[];if let handler {RemoveEventHandler(handler)};handler=nil}
}
