import AppKit
import Carbon

@MainActor final class SettingsController:NSWindowController {
    private let change:()->Void
    private var bindings:[HotKeyBinding]
    private var counts:[NSTextField]=[]
    init(onChange:@escaping()->Void){
        change=onChange;bindings=(UserDefaults.standard.data(forKey:"hotkeys").flatMap{try? JSONDecoder().decode([HotKeyBinding].self,from:$0)}) ?? HotKeyBinding.defaults
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:470),styleMask:[.titled,.closable],backing:.buffered,defer:false);super.init(window:w);w.title="设置";w.isReleasedWhenClosed=false;w.center()
        var rows:[NSView]=[]
        let title=NSTextField(labelWithString:"全局快捷键");title.font = .boldSystemFont(ofSize:13);rows.append(title)
        for (i,name) in ["区域截图","剪贴板贴图","历史记录"].enumerated(){let label=NSTextField(labelWithString:name);label.widthAnchor.constraint(equalToConstant:135).isActive=true;let key=ShortcutButton(binding:bindings[i]);key.onChange={ [weak self] binding in self?.bindings[i]=binding };rows.append(NSStackView(views:[label,key]))}
        rows.append(NSTextField(labelWithString:"点击快捷键后按组合键。至少包含 ⌘、⌃ 或 ⌥。"))
        let h=NSTextField(labelWithString:"历史保留上限");h.font = .boldSystemFont(ofSize:13);rows.append(h)
        for (label,key,fallback) in [("最多天数","historyDays",30),("最多截图","historyCount",200),("最大磁盘 MB","historyMB",1024)]{let text=NSTextField(labelWithString:label);text.widthAnchor.constraint(equalToConstant:135).isActive=true;let value=UserDefaults.standard.integer(forKey:key);let field=NSTextField(string:String(value>0 ? value:fallback));field.widthAnchor.constraint(equalToConstant:100).isActive=true;counts.append(field);rows.append(NSStackView(views:[text,field]))}
        let note=NSTextField(wrappingLabelWithString:"超限的非收藏历史会被自动清理。快捷键冲突时请换一组组合键。录屏原文件存于电影/PicShot，不计入截图历史。")
        note.textColor = .secondaryLabelColor;note.font = .systemFont(ofSize:11);rows.append(note)
        let save=NSButton(title:"保存",target:self,action:#selector(saveSettings));rows.append(save)
        let stack=NSStackView(views:rows);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false;w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:20)])
    }
    required init?(coder:NSCoder){fatalError()}
    @objc private func saveSettings(){
        let values=counts.map{$0.integerValue};guard values.allSatisfy({$0>0}),values[0]<=3650,values[1]<=10000,values[2]<=102400 else{showError(PicShotError.message("请填写有效的正数（最多 3650 天、10000 张、102400 MB）"));return}
        guard Set(bindings.map{"\($0.keyCode)-\($0.modifiers)"}).count == bindings.count else{showError(PicShotError.message("快捷键不能重复"));return}
        for (i,key) in ["historyDays","historyCount","historyMB"].enumerated(){UserDefaults.standard.set(values[i],forKey:key)}
        UserDefaults.standard.set(try? JSONEncoder().encode(bindings),forKey:"hotkeys");change();close()
    }
}

@MainActor final class ShortcutButton:NSButton {
    var binding:HotKeyBinding
    var onChange:((HotKeyBinding)->Void)?
    private var listening=false
    init(binding:HotKeyBinding){self.binding=binding;super.init(frame:.zero);target=self;action=#selector(begin);bezelStyle = .rounded;updateTitle()}
    required init?(coder:NSCoder){fatalError()}
    override var acceptsFirstResponder:Bool{true}
    @objc private func begin(){listening=true;title="按组合键…";window?.makeFirstResponder(self)}
    override func keyDown(with event:NSEvent){
        guard listening else{super.keyDown(with:event);return};if event.keyCode==53{listening=false;updateTitle();return}
        let flags=event.modifierFlags;guard !flags.intersection([.command,.control,.option]).isEmpty else{NSSound.beep();return}
        var modifiers:UInt32=0;if flags.contains(.command){modifiers |= UInt32(cmdKey)};if flags.contains(.shift){modifiers |= UInt32(shiftKey)};if flags.contains(.option){modifiers |= UInt32(optionKey)};if flags.contains(.control){modifiers |= UInt32(controlKey)}
        binding=HotKeyBinding(keyCode:UInt32(event.keyCode),modifiers:modifiers);listening=false;onChange?(binding);updateTitle()
    }
    private func updateTitle(){let m=binding.modifiers;let map:[UInt32:String]=[18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"]
        title=(m & UInt32(controlKey) != 0 ? "⌃":"")+(m & UInt32(optionKey) != 0 ? "⌥":"")+(m & UInt32(shiftKey) != 0 ? "⇧":"")+(m & UInt32(cmdKey) != 0 ? "⌘":"")+(map[binding.keyCode] ?? "键\(binding.keyCode)")
    }
}
