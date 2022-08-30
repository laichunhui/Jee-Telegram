import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import TextFormat
import AuthenticationServices
import CodeInputView
import PhoneNumberFormat
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import SolidRoundedButtonNode
import InvisibleInkDustNode
import AuthorizationUtils

final class AuthorizationSequenceCodeEntryControllerNode: ASDisplayNode, UITextFieldDelegate {
    private let strings: PresentationStrings
    private let theme: PresentationTheme
    
    private let animationNode: AnimatedStickerNode
    private let titleNode: ImmediateTextNode
    private let titleIconNode: ASImageNode
    private let currentOptionNode: ImmediateTextNode
    private var dustNode: InvisibleInkDustNode?
    
    private let currentOptionInfoNode: ASTextNode
    private let nextOptionTitleNode: ImmediateTextNode
    private let nextOptionButtonNode: HighlightableButtonNode
    
    private let dividerNode: AuthorizationDividerNode
    private var signInWithAppleButton: UIControl?
    
    private let codeInputView: CodeInputView
    private let errorTextNode: ImmediateTextNode
    
    private var codeType: SentAuthorizationCodeType?
    
    private let countdownDisposable = MetaDisposable()
    private var currentTimeoutTime: Int32?
    
    private var layoutArguments: (ContainerViewLayout, CGFloat)?
    
    private var appleSignInAllowed = false
    
    var phoneNumber: String = "" {
        didSet {
            if self.phoneNumber != oldValue {
                if let (layout, navigationHeight) = self.layoutArguments {
                    self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .immediate)
                }
            }
        }
    }
    
    var email: String?
    
    var currentCode: String {
        return self.codeInputView.text
    }
    
    var loginWithCode: ((String) -> Void)?
    var signInWithApple: (() -> Void)?
    
    var requestNextOption: (() -> Void)?
    var requestAnotherOption: (() -> Void)?
    var updateNextEnabled: ((Bool) -> Void)?
    
    var inProgress: Bool = false {
        didSet {
            self.codeInputView.alpha = self.inProgress ? 0.6 : 1.0
        }
    }
        
    init(strings: PresentationStrings, theme: PresentationTheme) {
        self.strings = strings
        self.theme = theme
        
        self.animationNode = DefaultAnimatedStickerNodeImpl()
        
        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 0
        self.titleNode.textAlignment = .center
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        
        self.titleIconNode = ASImageNode()
        self.titleIconNode.isLayerBacked = true
        self.titleIconNode.displayWithoutProcessing = true
        self.titleIconNode.displaysAsynchronously = false
        
        self.currentOptionNode = ImmediateTextNode()
        self.currentOptionNode.isUserInteractionEnabled = false
        self.currentOptionNode.displaysAsynchronously = false
        self.currentOptionNode.lineSpacing = 0.1
        self.currentOptionNode.maximumNumberOfLines = 0
        
        self.currentOptionInfoNode = ASTextNode()
        self.currentOptionInfoNode.isUserInteractionEnabled = false
        self.currentOptionInfoNode.displaysAsynchronously = false
        
        self.nextOptionTitleNode = ImmediateTextNode()
        
        self.nextOptionButtonNode = HighlightableButtonNode()
        self.nextOptionButtonNode.displaysAsynchronously = false
        let (nextOptionText, nextOptionActive) = authorizationNextOptionText(currentType: .sms(length: 5), nextType: .call, timeout: 60, strings: self.strings, primaryColor: self.theme.list.itemPrimaryTextColor, accentColor: self.theme.list.itemAccentColor)
        self.nextOptionTitleNode.attributedText = nextOptionText
        self.nextOptionButtonNode.isUserInteractionEnabled = nextOptionActive
        self.nextOptionButtonNode.addSubnode(self.nextOptionTitleNode)
        
        self.codeInputView = CodeInputView()
        self.codeInputView.textField.keyboardAppearance = self.theme.rootController.keyboardColor.keyboardAppearance
        self.codeInputView.textField.returnKeyType = .done
        self.codeInputView.textField.disableAutomaticKeyboardHandling = [.forward, .backward]
        if #available(iOSApplicationExtension 12.0, iOS 12.0, *) {
            self.codeInputView.textField.textContentType = .oneTimeCode
        }
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            self.codeInputView.textField.keyboardType = .asciiCapableNumberPad
        } else {
            self.codeInputView.textField.keyboardType = .numberPad
        }
        
        self.errorTextNode = ImmediateTextNode()
        self.errorTextNode.alpha = 0.0
        self.errorTextNode.displaysAsynchronously = false
        self.errorTextNode.textAlignment = .center
        
        self.dividerNode = AuthorizationDividerNode(theme: self.theme, strings: self.strings)
        
        if #available(iOS 13.0, *) {
            self.signInWithAppleButton = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: theme.overallDarkAppearance ? .white : .black)
            self.signInWithAppleButton?.isHidden = true
            (self.signInWithAppleButton as? ASAuthorizationAppleIDButton)?.cornerRadius = 11
        }
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.backgroundColor = self.theme.list.plainBackgroundColor
        
        self.addSubnode(self.codeInputView)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.titleIconNode)
        self.addSubnode(self.currentOptionNode)
        self.addSubnode(self.currentOptionInfoNode)
        self.addSubnode(self.nextOptionButtonNode)
        self.addSubnode(self.animationNode)
        self.addSubnode(self.dividerNode)
        self.addSubnode(self.errorTextNode)
        
        self.codeInputView.updated = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.textChanged(text: strongSelf.codeInputView.text)
        }
        
        self.nextOptionButtonNode.addTarget(self, action: #selector(self.nextOptionNodePressed), forControlEvents: .touchUpInside)
        self.signInWithAppleButton?.addTarget(self, action: #selector(self.signInWithApplePressed), for: .touchUpInside)
    }
    
    deinit {
        self.countdownDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        if let signInWithAppleButton = self.signInWithAppleButton {
            self.view.addSubview(signInWithAppleButton)
        }
    }
    
    func updateCode(_ code: String) {
        self.codeInputView.text = code
        self.textChanged(text: code)

        if let codeType = self.codeType {
            var codeLength: Int32?
            switch codeType {
                case let .call(length):
                    codeLength = length
                case let .otherSession(length):
                    codeLength = length
                case let .missedCall(_, length):
                    codeLength = length
                case let .sms(length):
                    codeLength = length
                default:
                    break
            }
            if let codeLength = codeLength, code.count == Int(codeLength) {
                self.loginWithCode?(code)
            }
        }
    }
    
    func resetCode() {
        self.codeInputView.text = ""
    }
    
    func updateData(number: String, email: String?, codeType: SentAuthorizationCodeType, nextType: AuthorizationCodeNextType?, timeout: Int32?, appleSignInAllowed: Bool) {
        self.codeType = codeType
        self.phoneNumber = number
        self.email = email
        
        var appleSignInAllowed = appleSignInAllowed
        if #available(iOS 13.0, *) {
        } else {
            appleSignInAllowed = false
        }
        self.appleSignInAllowed = appleSignInAllowed
        
        self.currentOptionNode.attributedText = authorizationCurrentOptionText(codeType, phoneNumber: self.phoneNumber, email: self.email, strings: self.strings, primaryColor: self.theme.list.itemPrimaryTextColor, accentColor: self.theme.list.itemAccentColor)
        if case .missedCall = codeType {
            self.currentOptionInfoNode.attributedText = NSAttributedString(string: self.strings.Login_CodePhonePatternInfoText, font: Font.regular(17.0), textColor: self.theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        } else {
            self.currentOptionInfoNode.attributedText = NSAttributedString(string: "", font: Font.regular(17.0), textColor: self.theme.list.itemPrimaryTextColor)
        }
        if let timeout = timeout {
            #if DEBUG
            let timeout = min(timeout, 5)
            #endif
            self.currentTimeoutTime = timeout
            let disposable = ((Signal<Int, NoError>.single(1) |> delay(1.0, queue: Queue.mainQueue())) |> restart).start(next: { [weak self] _ in
                if let strongSelf = self {
                    if let currentTimeoutTime = strongSelf.currentTimeoutTime, currentTimeoutTime > 0 {
                        strongSelf.currentTimeoutTime = currentTimeoutTime - 1
                        let (nextOptionText, nextOptionActive) = authorizationNextOptionText(currentType: codeType, nextType: nextType, timeout: strongSelf.currentTimeoutTime, strings: strongSelf.strings, primaryColor: strongSelf.theme.list.itemPrimaryTextColor, accentColor: strongSelf.theme.list.itemAccentColor)
                        strongSelf.nextOptionTitleNode.attributedText = nextOptionText
                        strongSelf.nextOptionButtonNode.isUserInteractionEnabled = nextOptionActive
                        
                        if let layoutArguments = strongSelf.layoutArguments {
                            strongSelf.containerLayoutUpdated(layoutArguments.0, navigationBarHeight: layoutArguments.1, transition: .immediate)
                        }
                        /*if currentTimeoutTime == 1 {
                            strongSelf.requestNextOption?()
                        }*/
                    }
                }
            })
            self.countdownDisposable.set(disposable)
        } else {
            self.currentTimeoutTime = nil
            self.countdownDisposable.set(nil)
        }
        let (nextOptionText, nextOptionActive) = authorizationNextOptionText(currentType: codeType, nextType: nextType, timeout: self.currentTimeoutTime, strings: self.strings, primaryColor: self.theme.list.itemPrimaryTextColor, accentColor: self.theme.list.itemAccentColor)
        self.nextOptionTitleNode.attributedText = nextOptionText
        self.nextOptionButtonNode.isUserInteractionEnabled = nextOptionActive
        
        if let layoutArguments = self.layoutArguments {
            self.containerLayoutUpdated(layoutArguments.0, navigationBarHeight: layoutArguments.1, transition: .immediate)
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layoutArguments = (layout, navigationBarHeight)
        
        var insets = layout.insets(options: [])
        insets.top = layout.statusBarHeight ?? 20.0
                
        var animationName = "IntroMessage"
        if let codeType = self.codeType {
            switch codeType {
            case .missedCall:
                self.titleNode.attributedText = NSAttributedString(string: self.strings.Login_EnterMissingDigits, font: Font.semibold(28.0), textColor: self.theme.list.itemPrimaryTextColor)
            case .email:
                self.titleNode.attributedText = NSAttributedString(string: self.strings.Login_EnterCodeEmailTitle, font: Font.semibold(28.0), textColor: self.theme.list.itemPrimaryTextColor)
                animationName = "IntroLetter"
            case .sms:
                self.titleNode.attributedText = NSAttributedString(string: self.strings.Login_EnterCodeSMSTitle, font: Font.semibold(28.0), textColor: self.theme.list.itemPrimaryTextColor)
            default:
                self.titleNode.attributedText = NSAttributedString(string: self.strings.Login_EnterCodeTelegramTitle, font: Font.semibold(28.0), textColor: self.theme.list.itemPrimaryTextColor)
            }
        } else {
            self.titleNode.attributedText = NSAttributedString(string: self.strings.Login_EnterCodeTelegramTitle, font: Font.semibold(40.0), textColor: self.theme.list.itemPrimaryTextColor)
        }
        
        if let inputHeight = layout.inputHeight {
            if let codeType = self.codeType, case .email = codeType {
                insets.bottom = max(inputHeight, insets.bottom)
            } else {
                insets.bottom = max(inputHeight, layout.standardInputHeight)
            }
        }
        
        if !self.animationNode.visibility {
            self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(name: animationName), width: 256, height: 256, playbackMode: .once, mode: .direct(cachePathPrefix: nil))
            self.animationNode.visibility = true
        }
        
        let animationSize = CGSize(width: 100.0, height: 100.0)
        let titleSize = self.titleNode.updateLayout(CGSize(width: layout.size.width, height: CGFloat.greatestFiniteMagnitude))
        
        let currentOptionSize = self.currentOptionNode.updateLayout(CGSize(width: layout.size.width - 48.0, height: CGFloat.greatestFiniteMagnitude))
        let currentOptionInfoSize = self.currentOptionInfoNode.measure(CGSize(width: layout.size.width - 48.0, height: CGFloat.greatestFiniteMagnitude))
        let nextOptionSize = self.nextOptionTitleNode.updateLayout(CGSize(width: layout.size.width, height: CGFloat.greatestFiniteMagnitude))
        
        let codeLength: Int
        var codePrefix: String = ""
        switch self.codeType {
        case .flashCall:
            codeLength = 6
        case let .call(length):
            codeLength = Int(length)
        case let .otherSession(length):
            codeLength = Int(length)
        case let .missedCall(prefix, length):
            if prefix.hasPrefix("+") {
                codePrefix = prefix
            } else {
                codePrefix = InteractivePhoneFormatter().updateText("+" + prefix).1
            }
            codeLength = Int(length)
        case let .sms(length):
            codeLength = Int(length)
        case let .email(_, length, _, _, _):
            codeLength = Int(length)
        case .emailSetupRequired:
            codeLength = 6
        case .none:
            codeLength = 6
        }
        
        let codeFieldSize = self.codeInputView.update(
            theme: CodeInputView.Theme(
                inactiveBorder: self.theme.list.itemPlainSeparatorColor.argb,
                activeBorder: self.theme.list.itemAccentColor.argb,
                succeedBorder: self.theme.list.itemDisclosureActions.constructive.fillColor.argb,
                failedBorder: self.theme.list.itemDestructiveColor.argb,
                foreground: self.theme.list.itemPrimaryTextColor.argb,
                isDark: self.theme.overallDarkAppearance
            ),
            prefix: codePrefix,
            count: codeLength,
            width: layout.size.width - 28.0
        )
        
        var items: [AuthorizationLayoutItem] = []
        items.append(AuthorizationLayoutItem(node: self.animationNode, size: animationSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        self.animationNode.updateLayout(size: animationSize)
        
        var additionalBottomInset: CGFloat = 20.0
        if let codeType = self.codeType {
            switch codeType {
            case .otherSession:
                self.titleIconNode.isHidden = false
                
                if self.titleIconNode.image == nil {
                    self.titleIconNode.image = generateImage(CGSize(width: 81.0, height: 52.0), rotatedContext: { size, context in
                        context.clear(CGRect(origin: CGPoint(), size: size))
                        
                        context.setFillColor(theme.list.itemPrimaryTextColor.cgColor)
                        context.setStrokeColor(theme.list.itemPrimaryTextColor.cgColor)
                        context.setLineWidth(2.97)
                        let _ = try? drawSvgPath(context, path: "M9.87179487,9.04664384 C9.05602951,9.04664384 8.39525641,9.70682916 8.39525641,10.5205479 L8.39525641,44.0547945 C8.39525641,44.8685133 9.05602951,45.5286986 9.87179487,45.5286986 L65.1538462,45.5286986 C65.9696115,45.5286986 66.6303846,44.8685133 66.6303846,44.0547945 L66.6303846,10.5205479 C66.6303846,9.70682916 65.9696115,9.04664384 65.1538462,9.04664384 L9.87179487,9.04664384 S ")
                        
                        let _ = try? drawSvgPath(context, path: "M0,44.0547945 L75.025641,44.0547945 C75.025641,45.2017789 74.2153348,46.1893143 73.0896228,46.4142565 L66.1123641,47.8084669 C65.4749109,47.9358442 64.8264231,48 64.1763458,48 L10.8492952,48 C10.1992179,48 9.55073017,47.9358442 8.91327694,47.8084669 L1.93601826,46.4142565 C0.810306176,46.1893143 0,45.2017789 0,44.0547945 Z ")
                        
                        let _ = try? drawSvgPath(context, path: "M2.96153846,16.4383562 L14.1495726,16.4383562 C15.7851852,16.4383562 17.1111111,17.7631027 17.1111111,19.3972603 L17.1111111,45.0410959 C17.1111111,46.6752535 15.7851852,48 14.1495726,48 L2.96153846,48 C1.32592593,48 0,46.6752535 0,45.0410959 L0,19.3972603 C0,17.7631027 1.32592593,16.4383562 2.96153846,16.4383562 Z ")

                        context.setStrokeColor(theme.list.plainBackgroundColor.cgColor)
                        context.setLineWidth(1.65)
                        let _ = try? drawSvgPath(context, path: "M2.96153846,15.6133562 L14.1495726,15.6133562 C16.2406558,15.6133562 17.9361111,17.3073033 17.9361111,19.3972603 L17.9361111,45.0410959 C17.9361111,47.1310529 16.2406558,48.825 14.1495726,48.825 L2.96153846,48.825 C0.870455286,48.825 -0.825,47.1310529 -0.825,45.0410959 L-0.825,19.3972603 C-0.825,17.3073033 0.870455286,15.6133562 2.96153846,15.6133562 S ")
                        
                        context.setFillColor(theme.list.plainBackgroundColor.cgColor)
                        let _ = try? drawSvgPath(context, path: "M1.64529915,20.3835616 L15.465812,20.3835616 L15.465812,44.0547945 L1.64529915,44.0547945 Z ")
                        
                        context.setFillColor(theme.list.itemAccentColor.cgColor)
                        let _ = try? drawSvgPath(context, path: "M66.4700855,0.0285884455 C60.7084674,0.0285884455 55.9687848,4.08259697 55.9687848,9.14830256 C55.9687848,12.0875991 57.5993165,14.6795278 60.0605723,16.3382966 C60.0568181,16.4358994 60.0611217,16.5884309 59.9318097,17.067302 C59.7721478,17.6586615 59.4575977,18.4958519 58.8015608,19.4258487 L58.3294314,20.083383 L59.1449275,20.0976772 C61.9723538,20.1099725 63.6110772,18.2528913 63.8662207,17.9535438 C64.7014993,18.1388449 65.5698144,18.2680167 66.4700855,18.2680167 C72.2312622,18.2680167 76.9713861,14.2140351 76.9713861,9.14830256 C76.9713861,4.08256999 72.2312622,0.0285884455 66.4700855,0.0285884455 Z ")
                        
                        let _ = try? drawSvgPath(context, path: "M64.1551769,18.856071 C63.8258967,19.1859287 63.4214479,19.5187 62.9094963,19.840779 C61.8188563,20.5269227 60.5584776,20.9288319 59.1304689,20.9225505 L56.7413094,20.8806727 L57.6592902,19.6022014 L58.127415,18.9502938 C58.6361919,18.2290526 58.9525079,17.5293964 59.1353377,16.8522267 C59.1487516,16.8025521 59.1603548,16.7584153 59.1703974,16.7187893 C56.653362,14.849536 55.1437848,12.1128655 55.1437848,9.14830256 C55.1437848,3.61947515 60.2526259,-0.796411554 66.4700855,-0.796411554 C72.6872626,-0.796411554 77.7963861,3.61958236 77.7963861,9.14830256 C77.7963861,14.6770228 72.6872626,19.0930167 66.4700855,19.0930167 C65.7185957,19.0930167 64.9627196,19.0118067 64.1551769,18.856071 S ")
                    })
                }
                
//                items.append(AuthorizationLayoutItem(node: self.titleIconNode, size: self.titleIconNode.image!.size, spacingBefore: AuthorizationLayoutItemSpacing(weight: 41.0, maxValue: 41.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 18.0, maxValue: 18.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                items.append(AuthorizationLayoutItem(node: self.currentOptionNode, size: currentOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.codeInputView, size: codeFieldSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 30.0, maxValue: 30.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.nextOptionButtonNode, size: nextOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 50.0, maxValue: 120.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            case .missedCall:
                self.titleIconNode.isHidden = false
                
                if self.titleIconNode.image == nil {
                    self.titleIconNode.image = generateImage(CGSize(width: 72.0, height: 72.0), rotatedContext: { size, context in
                        context.clear(CGRect(origin: CGPoint(), size: size))
                        
                        context.setFillColor(theme.list.itemAccentColor.cgColor)
                        let _ = try? drawSvgPath(context, path: "M42,10.5 C41.1716,10.5 40.5,11.1716 40.5,12 C40.5,12.8284 41.1716,13.5 42,13.5 L51.3787,13.5 L36,28.8787 L19.0607,11.9393 C18.4749,11.3536 17.5251,11.3536 16.9393,11.9393 C16.3536,12.5251 16.3536,13.4749 16.9393,14.0607 L34.9393,32.0607 C35.5251,32.6464 36.4749,32.6464 37.0607,32.0607 L53.5,15.6213 L53.5,25 C53.5,25.8284 54.1716,26.5 55,26.5 C55.8284,26.5 56.5,25.8284 56.5,25 L56.5,12 C56.5,11.1716 55.8284,10.5 55,10.5 L42,10.5 Z ")
                        
                        context.setFillColor(theme.list.itemPrimaryTextColor.cgColor)
                        
                        let _ = try? drawSvgPath(context, path: "M35.9832,37.4038 C46.3353,37.4066 56.7252,39.7842 62.0325,45.0915 C64.3893,47.4483 65.7444,50.3613 65.6897,53.8677 C65.6717,56.0012 64.9858,57.8376 63.8173,59.0061 C62.8158,60.0076 61.4987,60.5082 59.9403,60.248 L51.6994,58.3061 C49.2077,57.719 47.3333,55.6605 46.9816,53.1249 L46.264,47.9528 C46.2639,47.5446 46.1154,47.2478 45.8742,47.0065 C45.6515,46.7838 45.3175,46.6353 45.0206,46.5239 C43.3508,45.9298 39.7701,45.5763 35.9855,45.5753 C32.2194,45.5557 28.6389,45.9815 26.9694,46.5005 C26.6726,46.6117 26.3387,46.76 26.079,47.0197 C25.8194,47.2793 25.6525,47.5947 25.6526,48.0028 L24.9872,53.09 C24.6524,55.6494 22.7664,57.7335 20.253,58.3214 L11.8346,60.2905 C10.2949,60.5684 9.1074,60.0486 8.2166,59.1579 C6.9733,57.9145 6.3791,55.9107 6.3229,53.9628 C6.1921,50.4193 7.4343,47.5069 9.8639,45.0773 C15.1684,39.7728 25.6683,37.401 35.9832,37.4038 Z ")
                    })
                }
                
                items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 18.0, maxValue: 18.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                items.append(AuthorizationLayoutItem(node: self.currentOptionNode, size: currentOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.codeInputView, size: codeFieldSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 40.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.currentOptionInfoNode, size: currentOptionInfoSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 60.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.nextOptionButtonNode, size: nextOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 50.0, maxValue: 120.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            default:
                self.titleIconNode.isHidden = true
                items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 18.0, maxValue: 18.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                items.append(AuthorizationLayoutItem(node: self.currentOptionNode, size: currentOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 18.0, maxValue: 18.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                
                items.append(AuthorizationLayoutItem(node: self.codeInputView, size: codeFieldSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 30.0, maxValue: 30.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 104.0, maxValue: 104.0)))
                /*items.append(AuthorizationLayoutItem(node: self.codeField, size: CGSize(width: layout.size.width - 88.0, height: 44.0), spacingBefore: AuthorizationLayoutItemSpacing(weight: 40.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                items.append(AuthorizationLayoutItem(node: self.codeSeparatorNode, size: CGSize(width: layout.size.width - 88.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))*/
                                
                if self.appleSignInAllowed, let signInWithAppleButton = self.signInWithAppleButton {
                    additionalBottomInset = 80.0
                    
                    self.nextOptionButtonNode.isHidden = true
                    signInWithAppleButton.isHidden = false

                    let inset: CGFloat = 24.0
                    let buttonSize = CGSize(width: layout.size.width - inset * 2.0, height: 50.0)
                    transition.updateFrame(view: signInWithAppleButton, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - buttonSize.width) / 2.0), y: layout.size.height - insets.bottom - buttonSize.height - inset), size: buttonSize))
                    
                    let dividerSize = self.dividerNode.updateLayout(width: layout.size.width)
                    transition.updateFrame(node: self.dividerNode, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - dividerSize.width) / 2.0), y: layout.size.height - insets.bottom - buttonSize.height - inset - dividerSize.height), size: dividerSize))
                } else {
                    self.signInWithAppleButton?.isHidden = true
                    self.dividerNode.isHidden = true
                    self.nextOptionButtonNode.isHidden = false
                    items.append(AuthorizationLayoutItem(node: self.nextOptionButtonNode, size: nextOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 50.0, maxValue: 120.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
                }
            }
        } else {
            self.titleIconNode.isHidden = true
            items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            items.append(AuthorizationLayoutItem(node: self.currentOptionNode, size: currentOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 10.0, maxValue: 10.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            
            items.append(AuthorizationLayoutItem(node: self.codeInputView, size: codeFieldSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 40.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            
            items.append(AuthorizationLayoutItem(node: self.nextOptionButtonNode, size: nextOptionSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 50.0, maxValue: 120.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        }
        
        let _ = layoutAuthorizationItems(bounds: CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: layout.size.width, height: layout.size.height - insets.top - insets.bottom - additionalBottomInset)), items: items, transition: transition, failIfDoesNotFit: false)
        
        if let textLayout = self.currentOptionNode.cachedLayout, !textLayout.spoilers.isEmpty {
            if self.dustNode == nil {
                let dustNode = InvisibleInkDustNode(textNode: nil)
                self.dustNode = dustNode
                self.currentOptionNode.supernode?.insertSubnode(dustNode, aboveSubnode: self.currentOptionNode)
                
            }
            if let dustNode = self.dustNode {
                let textFrame = self.currentOptionNode.frame
                dustNode.update(size: textFrame.size, color: self.theme.list.itemSecondaryTextColor, textColor: self.theme.list.itemPrimaryTextColor, rects: textLayout.spoilers.map { $0.1.offsetBy(dx: 3.0, dy: 3.0).insetBy(dx: 1.0, dy: 1.0) }, wordRects: textLayout.spoilerWords.map { $0.1.offsetBy(dx: 3.0, dy: 3.0).insetBy(dx: 1.0, dy: 1.0) })
                transition.updateFrame(node: dustNode, frame: textFrame.insetBy(dx: -3.0, dy: -3.0).offsetBy(dx: 0.0, dy: 3.0))
            }
        } else if let dustNode = self.dustNode {
            self.dustNode = nil
            dustNode.removeFromSupernode()
        }
        
        self.nextOptionTitleNode.frame = self.nextOptionButtonNode.bounds
    }
    
    func activateInput() {
        let _ = self.codeInputView.becomeFirstResponder()
    }
    
    func animateError() {
        self.codeInputView.layer.addShakeAnimation()
    }
    
    func animateError(text: String) {
        self.codeInputView.animateError()
        self.codeInputView.layer.addShakeAnimation(amplitude: -30.0, duration: 0.5, count: 6, decay: true)
        
        self.errorTextNode.attributedText = NSAttributedString(string: text, font: Font.regular(17.0), textColor: self.theme.list.itemDestructiveColor, paragraphAlignment: .center)
        
        if let (layout, _) = self.layoutArguments {
            let errorTextSize = self.errorTextNode.updateLayout(CGSize(width: layout.size.width - 48.0, height: .greatestFiniteMagnitude))
            self.errorTextNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - errorTextSize.width) / 2.0), y: self.codeInputView.frame.maxY + 28.0), size: errorTextSize)
        
        }
        self.errorTextNode.alpha = 1.0
        self.errorTextNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
        self.errorTextNode.layer.addShakeAnimation(amplitude: -8.0, duration: 0.5, count: 6, decay: true)
        
        Queue.mainQueue().after(0.85) {
            self.errorTextNode.alpha = 0.0
            self.errorTextNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15)
        }
    }
    
    func animateSuccess() {
        self.codeInputView.animateSuccess()
        
        let values: [NSNumber] = [1.0, 1.1, 1.0]
        self.codeInputView.layer.animateKeyframes(values: values, duration: 0.4, keyPath: "transform.scale")
    }
    
    @objc func codeFieldTextChanged(_ textField: UITextField) {
        self.textChanged(text: textField.text ?? "")
    }
        
    private func textChanged(text: String) {
        self.updateNextEnabled?(!text.isEmpty)
        if let codeType = self.codeType {
            var codeLength: Int32?
            switch codeType {
                case let .call(length):
                    codeLength = length
                case let .otherSession(length):
                    codeLength = length
                case let .missedCall(_, length):
                    codeLength = length
                case let .sms(length):
                    codeLength = length
                case let .email(_, length, _, _, _):
                    codeLength = length
                default:
                    break
            }
            if let codeLength = codeLength, text.count == Int(codeLength) {
                self.loginWithCode?(text)
            }
        }
    }
    
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if self.inProgress {
            return false
        }
        var result = ""
        for c in string {
            if c.unicodeScalars.count == 1 {
                let scalar = c.unicodeScalars.first!
                if scalar >= "0" && scalar <= "9" {
                    result.append(c)
                }
            }
        }
        if result != string {
            textField.text = result
            self.codeFieldTextChanged(textField)
            return false
        }
        return true
    }
    
    @objc func nextOptionNodePressed() {
        self.requestAnotherOption?()
    }
    
    @objc func signInWithApplePressed() {
        self.signInWithApple?()
    }
}