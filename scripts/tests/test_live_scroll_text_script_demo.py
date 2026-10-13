"""Owned deterministic adversarial inputs, never evidence of native execution."""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPTS = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result

C = module('live_scroll_text_reader_tests', SCRIPTS/'check-live-scroll-text-script-demo.py')
T = module('saved_text_reader_inputs', SCRIPTS/'tests/test_text_script_demo.py')
SOURCE = T.SOURCE
IDS = [prefix+'1111111-2222-3333-4444-555555555555' for prefix in 'EF12']
sha, dump, rect = T.sha, T.dump, T.rect
SOURCE_PNG, SOURCE_HASH = T.T.png(C.WIDTH, C.HEIGHT)
CHOICE_LIGHT_PNG, CHOICE_LIGHT_HASH = T.T.png(460,600,(240,240,240,255))
CHOICE_DARK_PNG, CHOICE_DARK_HASH = T.T.png(460,600,(30,30,30,255))

# Exact archived native layout bytes from the generated-acquisition build281
# witness, source b5f39ed815b391ea97119da4a21bffa57db3115c, Actions run38445553179.
# Archive SHA256 c391253cff85f5a8a34dfc57fff304f8b7cacce6960fb0e98ac09cf503c16789.
# Embedding the bounded JSON keeps this regression portable without introducing
# another fixture file. These old layouts cannot qualify the current package.
RETAINED_281_LAYOUTS = {
    'failure-light': ('2ad854977e6cfac90fa0ed195a2b4199f820db4dde79b27f5885a10361836a29', 48571, (
        'eNrlXVtv20Yafc+vMPwcGeSQMyT3Lemi3QV2gyDupg/FPtASZRNlKK1IxckWAYwg8aWO1wZy28ZOUwPxJutcNzXqxHZiYH9KKtL2'
        'U/5CeVFsShqKFDmkSOnNpihx+PGcOd+c+Tjz/amRkVGxWpXEmqgWpdGRP4yMKvLklD562v6kKKoVVS6KyoWvzp45L1+RlPE/nQEQ'
        'OefxLCWwvCQCmi9PWH9BmuX4EgcQBQWaE/hSGUyUS0IJlCkalQW2yLCSVC7TkKW4YhlS7iXKsiKp4iX30lqxVlGUgi5d0QvW33JV'
        'L5RFWanXpILTqrGqOul+bUpyWml9CXCUc0QRr1bqzpHvrX/t27K+ol6SVP2CVNRFdVKRtPH6hKbLel2XSvaJZVHRpNPu2cWKqlvn'
        'nq3U1ZJ28iu4SzlHp+WSPmUfRODk4BX7wMm/V51/nf+ueS5j3aNzhW+b532+kt3mYlHSNHlCVmT96l/ECUlx4jJ62ueUi6JSd0PX'
        'eDtjPl835zeN1Q+f9m6ZtxaO1neMnWVz4cnh+q0R+uPMbWak8XbTvL3UeL/2aW+1sXvTWHtqrj0313Ya+w+NF/82Xj5ovFv4beZ6'
        'y+UsWGh6pfbnPzbbfPzR3z1nFRVRcz4fPTf+tfX0vpQlpeT9GesZTyhu1PVaXfJ8Uq4rype1JgJOQtESeJo97f3gOPaQ51s+cOJP'
        'o5ZjzkMALHV87Jrn4lNyqSSpmFbJTlMtAlR1G33FKVFWC5N1ueTQxHuiqskl6aIsTVcrNR3zS9/Jqvtb5faYVKZVbETs47VvrK9V'
        'ps/VL01INeeuvDGwiSJJKtGwWTTujBviaGzcbIYmCju9UlF0udqB/stWoM+L7m1862kuddr3nxPAnmq7kWDiGdtv3EYePLjh3uTR'
        'bfs+jeVbxtzu4f6KdZPec9x7CUHXmBSzyWRjjhzFBN4PKwBDMaETKjSABCimyJoejV66ffep0qunkAFAd8YMQtSdXslQgvb9JxZZ'
        'Eof9uJMeWA8Mj3qPnIeGPYV/hDTsfIIMRlYAEwnzqqjLl6UCiIb0ij7VGoPEkd5DlAAFMTIC2b7jHMTSgfe3jYWlT3sPzLXNo5kF'
        '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'
    )),
    'failure-dark': ('9af59cf22d6417de3c4807d20a6a711933dd028bf1f486a4587c19ca09b635a8', 48569, (
        'eNrlXV1v01gavudXVL0mlc+xz7G9dzCrmV1pF6HpLHMx2gs3cVsL42QTh8KOkCoE/ZjSbSW+dmgZphJd2PK5TDWFtlBpfwpTu+0V'
        'f2H8EVonOY4d+9ixkwsk6jix/fp5zvO+z3nt8/2poaFhqVKRpaqkFeXhoT8MDZek6sXh0/YHRUkra0pRUr/+6uyZ88oVWR390xmI'
        'sLMbx4MxhCE7zgFZlMTx0jhg2PExIJeAUCoJ3LggSbL1b7zIcwIDGJErYoQ4meeKkOekknuIcUWVNemSe+RasVpW1YIuX9EL1v+V'
        'il4YlxS1XpUL9kmNVLQJ91uTsjIxqdvfgTzjbFGlq+W6s+V760/7olRlQrska/rXclGXtAlVro3Wx2q6otd1uWTvOC6pNfm0u3ex'
        'rOnWvmfLda1UO/kV0qGcrVNKSZ+0N2J4svGKveHkz6vOn85f1zyHsS7ROcJ3jf0+H8k+52JRrtWUMUVV9Kt/kcZk1QnL8GmfXS5I'
        'at2N3P7bafP5mjm3Yax8+LR7y7w1f7S2bWwvmfNPDtduDYGP07fZof23G+btxf33q592V/Z3bhqrT83V5+bq9v7eQ+PFv42XD/bf'
        'zf82fb3pcBYoanq5+uc/Ns75+KO/e/YqqlLN+Xz43Og31s37UpHVkvdnrFs8prpR16t12fPJeF1Vv6w2AHASiqbAA+6094Pj2CNB'
        'aPrAiT/ATducmwA55njbNc/BJ5VSSdYIZ6U4p2rhv6Lb4CtOSopWmKgrJYck3h21mlKSLyjyVKVc1Qm/dFHR3N8ab41JeUojRsTe'
        'Xv3W+lp56lz90phcda7KGwObJ7KsUQ0bBEJ73DAPiHGzCZoo7PRyWdWVShv6L1uBPi+5l/Gd53SZ075/nAD2VMuFBBPP2HrjnuTB'
        'gxvuRR7dtq/TWLplzO4c7i1bF+ndx72WEHSNSTGbTDbm6FFMFPywAgkUE9uhAiCiQDFVqenR6KXbV58qvboKGYSgPWYI4c70SoYS'
        'wPePWGRJHPajTnZg3TAy6j1yHhr2DPkWAtR+B1mCrEA2EuY1SVcuywUYDellfbI5BokjvYsoQQYRZARxPcc5jKUD728b84ufdh+Y'
        'qxtH0/Pmwn9DgD3gS1lOrHgmXF4lAgpjfrFerVqpd96zKlLMiEkVgrAzGzoDx8uPznt2zxhITQzMe7PGi/uHN6wze/5x+j+Ja8PZ'
        'uq6XNYrKwELybRZx+20W+fa7LNCghqcQrkXjx1hbXBInSDeRgyIhlUQggCAdwEVPPZquAiScGHWiSysXPOHqgJaQjAkSlSjUaVGK'
        'kxGSI6gKI1CTlUZahXKjJF3EiQVMBCXpAVGosebw5Yf9t9uuwh3X3v2jI1a9TCqsxYSUpCarclHPvYYQo8YxIIKIBOIrIYbAhKUk'
        'mDehBaUBmgxKCWBYUrbN0NYSPu9aQgwUB2AEMekZYdJMxIzlxYMnr7NXqPvcXjZkoe5jwIRkgZB3FrBha3NOQAG1eRs+6KGepVd9'
        'f6YnAc6JTEgkMPS3GOYn9xISbibmSBkAhbzJmZrOCfq7ihjEmAR/2Aujlk211H64bm4v990ID/g4IzxgBmeI54SAorkNIPSQzlEe'
        '4glg9kH92szR9Lxxa9t49Cge9s+XK3+rUC+TW+o6z9jFE0Z7Qr0HqFTJ5Xo1an9HD6rkroIGMUsiQ5CD5IMbLyX89olJj8SFICwl'
        '/OtjFy4ZrI+hSOhB4AnlMRBiyQbMu2wQAwV5SKKKGJ8qNOlBjSvG3rOj6UduE9PQ+XNf5c9kBYKfXQjDZU+FiDxoHg/Kdb1S1wv/'
        'qCvFi6PSZbkllpnWkq5CSE6sANuZIGBkqBPU6PEEJdMNGIIXAZcYXlpIUMqkD0uaqyISLF59wuXfiCVECrJEHnHZ51Fi4rP/9oeD'
        'Jzv5k6CWlPukG5RQlyKGkIkVIEdBguqVfMpPN+HjGVJ6xvBBreqtwEqDKEnP9hHoElpjWrHSS33xaapjORJ7BJK+4Fj6gvPefkiK'
        'FE+aEOUAyiRRElSUhf5XFCQkpSgWYrUB0BTMRNKUhR5QhU1cUxYia0o7WvKiKhjTVxWhL1UFC5FUpSdUoacqjxeNuV/7xxpDYZ0x'
        'xNBzxorlytXcO2IorCHGCgFPz7ZjKiFOpPqQH4Ep3dpeDk4yaHexYd0un7mCsA8G5n82PqzZxQZ1nPSII5R1Y3BdLYTpuFq5ko7Y'
        'bhbLZ6VIBzlys3ouG7FdLC7WdDyEA+NisQKbSYJQ141B9a6o6IbjRvSvcpA8qxDKsdADYmTes8qVdhC9qpjawQ2MVxVCO3pCEXqP'
        'zm5uGisfBtCr8ikmI3lVFUUbIKsqqLmxHVIJUQKmaVURiNKtVWXDJM9OlRDr+ViIB8ep8jHCe00RyqoxuE6VINBxqvIkHPGNKi4r'
        'dTjMkVHVa9GI7VMJTCzVEAbHp0Igk/ygrhqD6lNRUQ3Hgehb3SDaVFxWanCYK5sqT8pBdKniKQfLDI5LFawcPWEINeUw7702drb7'
        '541umPSmBkBqKqTSl2uhUNLl3L/RDRPf20B4VJ0NasZtxxM9PuA0XSkCMUKLRAMVWXSkSItOQBI9QKyXVbG5fyadHCnCG45YkBlK'
        'UFMF97kNc2XTvPOuf7RBILz7mOcT04aadDn/ykCKGeTFCMrgh6mEyJD0i0t8KRL+xSU2PjKoEZiQHAtCAhqR+8fJSZGCIhNBI9Im'
        'B70OqaV75q9zg6AUAIuJSUVJqRWlaqkv1YLlQQS18MNVQoRIeqrClybhjacGRHIiGEBgElAM3I+KwQowgmKkTRB6ijH389GPj/vb'
        'cUJcglohq3KfWk48iiQVbYBKiANc0iLRzozw8uCiIieWE8JJqIPQj54TjyOpQ2qcSLPmdldXM7bemKvz3pVgzbl7B9fffZxeda22'
        'j9MPf5u+3rJGwv7OzYM7T/e3/2XsPTMXt47uvLS+uP92cX/3weHshvHDU3ch2b5cebkAOJ6GoaVLer02OAsvQyHgHXDp45Eei/lY'
        's4ZLy1b+eXR3z7oWY2vdWLx7sHvPWNoa+v/WkLvKtLm6Yby0ArFsr4t4/2fzl7vG6xl3JSxj5kfj5roxv3G4uWk+3LMu+/DV1tHs'
        '4uGru9bVOj/hvFDbWVHxufl8zTqOG7Yw0zbZOTNVPqPqctVVJwLSJVWZ0C7Jmv7tCTS57sceWVVHlX/KrXeew2gEs5ixpIITIEJN'
        'CannPSFdjWPFsqZbIwGRuHJJcZZ/dhcIdhaCJmQSHUZC67c/X4h3aZxwQySKuzg9G/SygNYrIQ6R1TrlYdJe+qIFRq0nkvxIiuKO'
        'pJgPaNvOAG11B/B6jRDJpvesZ+BMLZQVJV0mnWooIfB7E4nnd6aqUqUil2iNLPbP1Y7BG/VBXOPx/w431z/trrghM5Y2Gtu33hiz'
        'M8bjWWP9/cGDG26sj+XU2tnS4cNXM8bcM1eE3btnqbQ5/8TSWHdpxtbMr9N7VXpxIr2VE5ZHIwLgAWQwhAgLzTMIXMblBKSdccPA'
        'Ny2HkxO5KCsVvcD0k5rEzstx0OIx6ZM0pHj04MSoakU84YgyhsQWjpu/HN1/kYzb7DNUNntbLIxgVXccGGN5CXH7JrvNkicV/Rsr'
        'lqH7KdVybYDaKTkuIC9uh2/IkaZrc4CNRW1/zCfjlPuyWg3St/Y0ybtoWTdNng5Uu0ui2BFe5DFGLBYxJwpMc1MGjuPep5ZLsSm3'
        'ooKIhXljVoBj+yl3itusyqE0BpzYSQcbpq01ZNIRhXNxs47DvTvGyk8HL9cOlmdSzT2aG3CSzD160ZibcPJxSdKkiQFq2Q3MPvxg'
        'nEoO0jXT/bGfzGtLAjgeIRNBOFIm0sBtVwMFEkeQiFiW4VkRiiJuXow+Q6lI2ziTRC4StuU5bi6CBiAXCd0UHZiLUBx+6GYkINY4'
        'FYl6cTMS89H6werCwc5t86fV3vbeUTQtiG3aEUyLMMlBVa7VVb0/k4NI1oQfouhlAEkruC8nQitvAxSUuu4oLlhPHISjFNcdO+44'
        'vi+f4IlUOKdAB2qtdu68w/E8tTttnWqdCppXTc+JSd5y1o32fYhTr1Srsl69mnstIoYTQSGCGAUiOpWSles2FexAg2QaaMMSP0Lx'
        'KqKIEmpDuavBQxRGoAgEKPAiy/McO8AmOmBYwojE8vRLV3EASldiNBErRkgHkhiQ6BaxXKwiNgIHY0/lO0+8uW3RfWqqJ1wbcyh9'
        'U71ox17ty7oZoyimuh+MU8lQUMZN9SCOp2eqN3Dbn6Z6GqkJqbTmMH1THYEBNdUxH8VUpzj80M1HUP5M9R7kIl02F37hjmlf2EPa'
        '13UtE7P9oR+YT9pEqWuD8xR9iLn+niQkOOOdhlRTkYidhjZQ+7PPMJXJ/dAvIIibiAxqpyHxFQUhZvczl4LgrHQanvLs5mD/nIME'
        '56bV/ipLNWtwaLn9wxWLvu0bJ6WaO5DVHE4W7BgXrP/bTxWNS4pq/VAjnn7A8IACnzxQ5jXNTubLXDwcB9hFAnJp1QCBdVvKqnU1'
        'Zc2b/ny+1ikHup3OAYpC+zlgyDSfAjxZJqUBRxY0ncWUH0can1xQnCH+czhPNb7ZdMhT134HOQptZA=='
    )),
    'result-light': ('bf04c8363fdd0a00f2ee461b1c3836d3edea270a4ec1a27acc364bc982c37f2a', 46849, (
        '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'
    )),
    'result-dark': ('e4cd8922f207d245f266ab7fb4bf8899d15edbedde77b4fcb2dfb7b202696f19', 46847, (
        'eNrtXd9v1NgVfueviPLMRPa99rXdN9hqt5VahMiWfVj1wZlxEgvjmY5tAl0hRXRZkg0pkQJsC2FppGWh2UARRZuQBCL1T2HHTvLE'
        'v1D/GBLP+Hrssa899sy+ZTzO2D7+vvOdc+659351amxsXGw0JLEpqlVpfOw3Y+M1sXlp/LTzRVVU66pcFZULn509c16+KimTvzsD'
        'WOSeJrBVND0lcBLDijyY4kVWglBkpqpSDfI8YoRpxCOW4uE0gpChGMACRNNMrSpVKSAiybvEtKxIqnjZu7JWbdYVpaJLV/WK/bfc'
        '0CtNSTMUveLc00RDnfH+aVaSZ2Z1518AR7lHFPFa3XCPfGV/dJ5JkWfUy5KqX5CquqjOKJI2aUxpuqwbulRzTpwWFU067Z1drau6'
        'fe7ZuqHWtJNfwV3KPTon1/RZ5yACJwevOgdOPl5zP7qfrvsuYz+he4Uv2+d9vJJzz9WqpGnylKzI+rU/iFOS4lpl/HTIKRdFxfAM'
        '19qetzbXrYUN8+G7D3u3rduLR+s75s4da/Hp4frtMfr9/Coca21vWKvLrbdrH/YetnZvmmvPrLVNa22ntf/IfP4P88WD1pvFX+Zv'
        'dFzOxoSm15u//237no+/+rPvrKoiau734+cmP7ff3aeypNT8P2O/4SnFs7reNCTfN9OGonzabL//E1N0GJ5mTvu/OLY9y/MdX7j2'
        'p1HHMfclAIY6Pnbdd/FZuVaTVMxdye6t2vBv6EZTqlRnRVmtzBhyzeWI/0RVk2vSRVmaa9SbOuaXLsmq91vT3Tapz6lYizjHm1/Y'
        '/1afO2dcnpKa7lP5beDQRJJUomYDNB+0G+JorN0cfmYKO71eV3S5EUD/FdvQ50XvMb703S51OvTDCWBPdT1INPHMrVfeTR48+Np7'
        'yKNV5znNO7fNW7uH+yv2Q/rP8Z4lBl1TUswhk4M5chQT+DCsAAzFhCBUaMASoJgia3oyeunO0+dKr75MBgAdtBnLot70yoYSdOiH'
        'VGTJHPaTbnBgvzA86n1yHhv2FP4V0mzwDUKMrACYCPOqqMtXpApIhvS6Pttpg8yR3oeVAMViZIRlBo5zkEoH3q6ai8sf9h5YaxtH'
        '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'
    )),
}


def artifacts(phase):
    width=460 if phase=='choice' else 600
    rows = []
    for index, (identifier, label) in enumerate(C.PHASES[phase].items()):
        kind = 'field' if identifier.endswith(('.title', '.description', '.name', '.outputs', '-status')) or '-receipt-' in identifier else 'button'
        row = T.control(identifier, index, kind)
        row.update(text=label, tooltip=label, accessibilityValue=label, accessibilityLabel=label)
        if phase=='choice':
            row['fullFrame']['width']=row['screenFrame']['width']=412
            if kind=='field':row['alignmentWidth']=400
        if identifier.endswith('.choice'):
            row['class']='NSPopUpButton'
            row['tooltip']=row['accessibilityValue']=C.NAME+' · '+C.PHASES['choice']['scroll.live.textScript.choice.outputs']
        rows.append(row)
    if phase in ('failure','result'):
        guidance=T.control(C.GUIDANCE_ID,len(rows),'field')
        guidance={key:value for key,value in guidance.items() if key in C.CONTROL_KEYS}
        guidance.update(C.GUIDANCE_FIELDS)
        rows.append(guidance)
    return [dict(filename='scroll-text-script-'+phase+'-'+mode+'.png', appearance=mode, width=width, height=600,
        canonicalRGBAPixelSHA256=pixel_hash, layout=dict(phase='scroll-text-script-'+phase, passed=True, windowVisible=True,
            violations=[], fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False,
            windowNumber=12, windowFrame=rect(20,20,width,622), screenFrame=rect(0,0,1200,900),
            contentBounds=rect(0,0,width,600), controls=copy.deepcopy(rows)))
        for mode,pixel_hash in [('light',CHOICE_LIGHT_HASH if phase=='choice' else T.LIGHT_HASH), ('dark',CHOICE_DARK_HASH if phase=='choice' else T.DARK_HASH)]]


def report():
    reference = dict(width=C.WIDTH, height=C.HEIGHT, canonicalRGBAPixelSHA256=SOURCE_HASH)
    case = copy.deepcopy(C.CASE_FIXED)
    case.update(preRunFrontier=copy.deepcopy(C.FRONTIER), definitionID=IDS[0], requestID=IDS[2], runID=IDS[1],
        isolatedDefaultsBeforeSHA256='d'*64, isolatedDefaultsAfterSHA256='d'*64,
        sourceProviderCallsAtFailure=10, sourceProviderCallsAfterRetry=10,
        ocrTextSHA256=sha(b'ABC-123\nXYZ-987\nABC-123'), ocrTextBytes=len(b'ABC-123\nXYZ-987\nABC-123'), catalogBeforeSHA256='b'*64, catalogAfterSHA256='b'*64,
        generatedActualOCR='ABC-123\nXYZ-987\nABC-123', helperMetrics=[T.metrics(IDS[2])],
        acceptedImageReference=copy.deepcopy(reference), acceptedPNGFileSHA256=sha(SOURCE_PNG),
        sourceImageComparison=dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
            width=C.WIDTH, height=C.HEIGHT, expectedWidth=C.WIDTH, expectedHeight=C.HEIGHT,
            outputPixelSHA256=SOURCE_HASH, sourcePixelSHA256=SOURCE_HASH, method=C.C.COMPARISON),
        failureAttempts=dict(capture=0,ocr=1,transform=1,copy=1,committedCopy=0),
        attempts=dict(capture=0,ocr=1,transform=1,copy=2,committedCopy=1),
        viewportTrace=[dict(offset=offset,height=480+offset,acceptedObservations=i+1) for i,offset in enumerate(C.OFFSETS)],
        actionTrace=copy.deepcopy(C.ACTIONS), copiedTextSHA256=sha(C.EXPECTED.encode()))
    for phase in C.PHASES: case[phase+'Artifacts'] = artifacts(phase)
    value = copy.deepcopy(C.TOP_FIXED)
    value.update(sourceCommit=SOURCE, limits=copy.deepcopy(C.LIMITS), sourceReference=reference, sourcePNGFileSHA256=sha(SOURCE_PNG),
        ownership={key:True for key in C.OWNERS}, elapsedSeconds=10., copyRetry=case)
    return value


def fixture(root):
    root = root.resolve(strict=True)
    value = report(); case = value['copyRetry']
    for name in ('owned-numbered', 'accepted'): (root/('scroll-text-script-'+name+'.png')).write_bytes(SOURCE_PNG)
    (root/'scroll-text-script-source.js').write_bytes(C.SOURCE_BODY.encode())
    (root/'scroll-text-script-ocr.txt').write_bytes(case['generatedActualOCR'].encode())
    (root/'scroll-text-script-copied.txt').write_bytes(C.EXPECTED.encode())
    catalog = dict(version=1, selectedID=case['definitionID'], definitions=[dict(id=case['definitionID'],name=C.NAME,source=C.SOURCE_BODY)])
    dump(root/'scroll-text-script-catalog.json',catalog)
    case['catalogBeforeSHA256'] = case['catalogAfterSHA256'] = sha((root/'scroll-text-script-catalog.json').read_bytes())
    dump(root/'scroll-text-script-actions.json',dict(actionTrace=case['actionTrace'], failureReceipts=case['failureReceipts'], receipts=case['receipts']))
    for phase in C.PHASES:
        for artifact in case[phase+'Artifacts']:
            light,dark=(CHOICE_LIGHT_PNG,CHOICE_DARK_PNG) if phase=='choice' else (T.LIGHT_PNG,T.DARK_PNG)
            (root/artifact['filename']).write_bytes(light if artifact['appearance']=='light' else dark)
            dump(root/(artifact['filename'][:-4]+'-layout.json'),artifact)
    dump(root/'scroll-text-script-case.json',case)
    path = root/C.RAW_NAME; dump(path,value)
    return path


def installed_fixture(root):
    outer, proof, sources = T.fixture(root, include_current_long_image=False)
    launch_path=outer.with_name(outer.name+'.launcher.json')
    launch=json.loads(launch_path.read_text());launch['scope']=C.LAUNCH_SCOPE;dump(launch_path,launch)
    child_dir = outer.parent/'current-long-image'; child_dir.mkdir()
    child = fixture(child_dir)
    for path in (outer, outer.parent/'text-script-demo.json'):
        value = json.loads(path.read_text()); value['currentLongImage'] = json.loads(child.read_text()); dump(path,value)
    package = json.loads(proof.read_text())
    present = {row['path'] for row in package['sources']}
    for name in sorted(C.REQUIRED_SOURCES-present):
        path = sources/name; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(b'Owned synthetic current long image source inventory input')
        package['sources'].append(dict(path=name,bytes=path.stat().st_size,sha256=sha(path.read_bytes())))
    dump(proof,package)
    return outer,proof,sources


class ContractTests(unittest.TestCase):
    def test_complete_owned_contract(self):
        C.contract(report(),SOURCE)

    def test_every_top_level_and_case_field_is_required(self):
        original = report()
        for container in ((), ('copyRetry',)):
            baseline = original if not container else original[container[0]]
            for key in baseline:
                value = copy.deepcopy(original); target = value if not container else value[container[0]]; del target[key]
                with self.subTest(container=container,key=key), self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_unknown_fields_fail_at_bounded_levels(self):
        paths = [(), ('copyRetry',), ('ownership',), ('sourceReference',), ('copyRetry','attempts'),
            ('copyRetry','failureAttempts'), ('copyRetry','acceptedImageReference'), ('copyRetry','sourceImageComparison'),
            ('copyRetry','helperMetrics',0), ('copyRetry','helperMetrics',0,'signature'),
            ('copyRetry','choiceArtifacts',0), ('copyRetry','choiceArtifacts',0,'layout'),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0,'fullFrame'),
            ('copyRetry','actionTrace',0), ('copyRetry','viewportTrace',0), ('limits',),
            ('copyRetry','preRunFrontier'), ('copyRetry','receipts',0)]
        for path in paths:
            value = report(); target = value
            for key in path: target = target[key]
            target['unreviewed'] = 'payload'
            with self.subTest(path=path), self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_boolean_and_integer_type_substitutions_fail(self):
        original = report()
        for path in ((), ('copyRetry',), ('copyRetry','attempts'), ('copyRetry','failureAttempts'), ('copyRetry','preRunFrontier'), ('ownership',), ('limits',)):
            baseline = original
            for key in path: baseline = baseline[key]
            for key,item in baseline.items():
                if type(item) not in (bool,int): continue
                value = copy.deepcopy(original); target = value
                for part in path: target = target[part]
                target[key] = int(item) if type(item) is bool else bool(item)
                with self.subTest(path=path,key=key),self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_metrics_use_existing_strict_production_contract(self):
        for key,bad in [('outcome','failed'),('childExitConfirmed',False),('pipesDrained',False),
            ('admissionReleased',False),('requestID',IDS[3]),('sampledPeakResidentBytes',256*1024**2+1),
            ('residentSamples',0),('acceptedSeconds',3.1),('stderrBytes',1),('retainedResponseBytesAfterFinish',1),
            ('responseIdentityMatched',False),('observationScope','hard memory cap')]:
            value=report();value['copyRetry']['helperMetrics'][0][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.contract(value,SOURCE)
        value=report();value['copyRetry']['helperMetrics'][0]['signature']['helperEntitlements'].append('com.apple.security.network.client')
        with self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_layout_and_readability_fail_closed(self):
        for mutation in ('offscreen','clipped','overlap','missing','duplicate','wrong-class','foreign-window','forged-path','forged-parent','hidden','hit-test','unreadable','wrong-text'):
            value=report();artifact=value['copyRetry']['choiceArtifacts'][0];layout=artifact['layout'];rows=layout['controls']
            if mutation=='offscreen':layout['windowFrame']['x']=1199
            elif mutation=='clipped':rows[0]['fullFrame']['x']=599
            elif mutation=='overlap':rows[1]['fullFrame']=copy.deepcopy(rows[0]['fullFrame'])
            elif mutation=='missing':rows.pop(0)
            elif mutation=='duplicate':rows.append(copy.deepcopy(rows[0]))
            elif mutation=='wrong-class':rows[0]['class']='UnreviewedControl'
            elif mutation=='foreign-window':rows[0]['ownerWindowNumber']=99
            elif mutation=='forged-path':rows[1]['viewPath']=rows[0]['viewPath']
            elif mutation=='forged-parent':rows[0]['ancestorIDs']=[rows[1]['id']]
            elif mutation=='hidden':rows[0]['hidden']=True
            elif mutation=='hit-test':next(row for row in rows if row['kind']=='button')['hitTest']=False
            elif mutation=='unreadable':next(row for row in rows if row['kind']=='field')['fontSize']=10
            else:rows[0]['text']='unrelated content'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_counts_frontier_receipts_scope_and_cleanups(self):
        mutations=[('scope',lambda r:r.update(scope='unbounded installed acceptance')),
            ('viewport-boolean',lambda r:r['copyRetry']['viewportOffsets'].__setitem__(0,False)),
            ('source',lambda r:r.update(sourceCommit='b'*40)),
            ('capture',lambda r:r['copyRetry']['attempts'].update(capture=1)),
            ('repeat-ocr',lambda r:r['copyRetry']['attempts'].update(ocr=2)),
            ('repeat-helper',lambda r:r['copyRetry']['attempts'].update(transform=2)),
            ('repeat-copy',lambda r:r['copyRetry']['attempts'].update(copy=3)),
            ('repeat-commit',lambda r:r['copyRetry']['attempts'].update(committedCopy=2)),
            ('receipt',lambda r:r['copyRetry']['receipts'][0].update(characterCount=14)),
            ('forged-receipt-type',lambda r:r['copyRetry']['receipts'][0].update(characterCount=True)),
            ('pending-not-flushed',lambda r:r['copyRetry']['preRunFrontier'].update(pendingPixelRows=0)),
            ('cropped-output',lambda r:r['copyRetry']['acceptedImageReference'].update(height=1008)),
            ('wrong-output',lambda r:r['copyRetry'].update(generatedActualOutput='ABC-123')),
            ('retained-image',lambda r:r['copyRetry'].update(finalRetainedBytes=1)),
            ('retained-text',lambda r:r['copyRetry'].update(finalRetainedTextBytes=15)),
            ('repeat-render',lambda r:r['copyRetry'].update(textRenderCount=2)),
            ('provider-restarted',lambda r:r['copyRetry'].update(sourceProviderCallsAfterRetry=11)),
            ('owner-retained',lambda r:r['ownership'].update(runner=False)),
            ('early-helper',lambda r:r.update(finalHelperAdmissionOccupied=True)),
            ('source-mutated',lambda r:r['copyRetry'].update(savedDefinitionFrozen=False)),
            ('defaults-mutated',lambda r:r['copyRetry'].update(isolatedDefaultsAfterSHA256='e'*64)),
            ('catalog-mutated',lambda r:r['copyRetry'].update(catalogAfterSHA256='e'*64)),
            ('action-reordered',lambda r:r['copyRetry']['actionTrace'].reverse()),
            ('direct-call',lambda r:r['copyRetry']['actionTrace'][2].update(route='direct method')),
            ('unaccepted-frontier',lambda r:r['copyRetry']['viewportTrace'][-1].update(height=1008)),
            ('no-ocr-binding',lambda r:r['copyRetry'].update(ocrTextBytes=1)),
            ('wrong-ocr-order',lambda r:r['copyRetry'].update(generatedActualOCR='XYZ-987\nABC-123'))]
        for label,mutate in mutations:
            value=report();mutate(value)
            with self.subTest(mutation=label),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_every_nested_proof_field_is_required(self):
        paths=[('limits',),('ownership',),('sourceReference',),('copyRetry','preRunFrontier'),
            ('copyRetry','attempts'),('copyRetry','failureAttempts'),('copyRetry','sourceImageComparison'),
            ('copyRetry','acceptedImageReference'),('copyRetry','helperMetrics',0),
            ('copyRetry','helperMetrics',0,'signature'),('copyRetry','actionTrace',0),('copyRetry','viewportTrace',0),
            ('copyRetry','choiceArtifacts',0),('copyRetry','choiceArtifacts',0,'layout'),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0)]
        for path in paths:
            baseline=report()
            for key in path:baseline=baseline[key]
            for omitted in baseline:
                value=report();target=value
                for key in path:target=target[key]
                del target[omitted]
                with self.subTest(path=path,key=omitted),self.assertRaises(ValueError):C.contract(value,SOURCE)


class RetainedLayoutTests(unittest.TestCase):
    def retained(self, key):
        expected_hash,expected_size,encoded=RETAINED_281_LAYOUTS[key]
        raw=zlib.decompress(base64.b64decode(encoded,validate=True))
        self.assertEqual(len(raw),expected_size)
        self.assertEqual(sha(raw),expected_hash)
        return json.loads(raw)

    def test_exact_retained_native_failure_and_result_layouts(self):
        for key in RETAINED_281_LAYOUTS:
            artifact=self.retained(key);phase,theme=key.split('-')
            self.assertEqual(artifact['appearance'],theme)
            self.assertEqual(artifact['filename'],'scroll-text-script-'+key+'.png')
            controls=C.layout(artifact,phase)
            guidance=controls['capture-chain-guidance']
            self.assertEqual(guidance['class'],'NSTextField')
            self.assertEqual(guidance['text'],'一次截图，按顺序执行 1–3 个操作；仅在本机保存定义。')
            self.assertTrue(guidance['hidden'])

    def test_retained_guidance_has_exact_scoped_contract(self):
        for key in RETAINED_281_LAYOUTS:
            phase=key.split('-')[0]
            for field,bad in [('class','NSButtonTextField'),('kind','table'),('hidden',False),('hidden',1),
                ('text','unreviewed guidance'),('accessibilityValue','unreviewed guidance'),
                ('accessibilityLabel','unreviewed label'),('tooltip','unreviewed tooltip'),
                ('enabled',False),('insideViewport',False)]:
                artifact=self.retained(key)
                guidance=next(row for row in artifact['layout']['controls'] if row['id']=='capture-chain-guidance')
                guidance[field]=bad
                with self.subTest(layout=key,field=field,bad=bad),self.assertRaises(ValueError):C.layout(artifact,phase)

    def test_retained_guidance_keeps_schema_geometry_and_ownership_checks(self):
        for key in RETAINED_281_LAYOUTS:
            phase=key.split('-')[0]
            for mutation in ('missing','unknown-id','duplicate','unknown-field','missing-field','wrong-owner',
                             'unowned','wrong-screen-size','forged-path','forged-parent'):
                artifact=self.retained(key);rows=artifact['layout']['controls']
                guidance=next(row for row in rows if row['id']=='capture-chain-guidance')
                if mutation=='missing':rows.remove(guidance)
                elif mutation=='unknown-id':guidance['id']='capture-chain-guidance-extra'
                elif mutation=='duplicate':rows.append(copy.deepcopy(guidance))
                elif mutation=='unknown-field':guidance['notReviewed']=True
                elif mutation=='missing-field':del guidance['hidden']
                elif mutation=='wrong-owner':guidance['ownerWindowNumber']+=1
                elif mutation=='unowned':guidance['owned']=False
                elif mutation=='wrong-screen-size':guidance['screenFrame']['width']+=1
                elif mutation=='forged-path':guidance['viewPath']=rows[-1]['viewPath']
                else:guidance['ancestorIDs']=[rows[-1]['id']]
                with self.subTest(layout=key,mutation=mutation),self.assertRaises(ValueError):C.layout(artifact,phase)

    def test_hidden_guidance_cannot_be_transplanted_into_chooser(self):
        for key in RETAINED_281_LAYOUTS:
            guidance=next(row for row in self.retained(key)['layout']['controls'] if row['id']=='capture-chain-guidance')
            for choice in artifacts('choice'):
                row=copy.deepcopy(guidance);row['ownerWindowNumber']=choice['layout']['windowNumber'];row['viewPath']=[999]
                choice['layout']['controls'].append(row)
                with self.subTest(layout=key,theme=choice['appearance']),self.assertRaisesRegex(ValueError,'outside its progress phase'):
                    C.layout(choice,'choice')


class FileTests(unittest.TestCase):
    def test_standalone_fixture_is_unqualified_checker_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            result=C.validate(fixture(Path(temporary)),SOURCE)
            self.assertEqual(result['status'],'passed')
            for key in ('installerAcceptance','original227MemoryAcceptance','hardMemoryCapClaimed','sourceAndFinalPackageBound','installedIdentityBound'):
                self.assertFalse(result[key])

    def test_installed_source_and_final_package_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            result=C.validate(report_path,SOURCE,proof,sources)
            self.assertTrue(result['installedIdentityBound']);self.assertTrue(result['sourceAndFinalPackageBound'])

    def test_missing_raw_file_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));path=report_path.parent/'scroll-text-script-source.js';path.unlink()
            with self.assertRaisesRegex(ValueError,'missing'):C.validate(report_path,SOURCE)

    def test_every_physical_evidence_file_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for path in sorted(report_path.parent.iterdir()):
                original=path.read_bytes();path.unlink()
                with self.subTest(file=path.name),self.assertRaises(ValueError):C.validate(report_path,SOURCE)
                path.write_bytes(original)

    def test_extra_nested_symlinked_and_hardlinked_files_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));root=report_path.parent
            extra=root/'unreviewed.json';extra.write_text('{}')
            with self.assertRaisesRegex(ValueError,'unknown physical'):C.validate(report_path,SOURCE)
            extra.unlink();extra.mkdir()
            with self.assertRaisesRegex(ValueError,'unknown physical'):C.validate(report_path,SOURCE)
            extra.rmdir()
            source=root/'scroll-text-script-source.js';data=source.read_bytes();source.unlink()
            source.symlink_to(root/'scroll-text-script-copied.txt')
            with self.assertRaisesRegex(ValueError,'owned regular'):C.validate(report_path,SOURCE)
            source.unlink();source.hardlink_to(root/'scroll-text-script-copied.txt')
            with self.assertRaisesRegex(ValueError,'owned regular'):C.validate(report_path,SOURCE)
            source.unlink();source.write_bytes(data)

    def test_raw_bytes_catalog_case_layout_and_text_are_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for name in ('scroll-text-script-copied.txt','scroll-text-script-source.js','scroll-text-script-ocr.txt',
                         'scroll-text-script-catalog.json','scroll-text-script-case.json','scroll-text-script-actions.json',
                         'scroll-text-script-choice-light-layout.json','scroll-text-script-result-dark.png'):
                path=report_path.parent/name;original=path.read_bytes();path.write_bytes(original+b'corrupt')
                with self.subTest(file=name),self.assertRaises((ValueError,json.JSONDecodeError)):C.validate(report_path,SOURCE)
                path.write_bytes(original)

    def test_full_frontier_raw_pixel_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));value=json.loads(report_path.read_text())
            for height in (C.HEIGHT,1008):
                changed,_=T.T.png(C.WIDTH,height,(31,42,53,255))
                (report_path.parent/'scroll-text-script-accepted.png').write_bytes(changed)
                value['copyRetry']['acceptedPNGFileSHA256']=sha(changed);dump(report_path,value)
                with self.subTest(height=height),self.assertRaisesRegex(ValueError,'full final frontier pixels'):
                    C.validate(report_path,SOURCE)

    def test_raw_child_outer_launcher_and_source_cannot_diverge(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            launch_path=report_path.with_name(report_path.name+'.launcher.json')
            original=json.loads(launch_path.read_text())
            for key,bad in [('ownedExitConfirmed',False),('textScriptDiagnosticOnly',False),('timeoutSeconds',45),
                            ('selectedAppPath','/wrong/PicShot.app'),('launchedExecutablePath','/wrong/PicShot'),
                            ('unexpectedClaim',True)]:
                value=copy.deepcopy(original);value[key]=bad;dump(launch_path,value)
                with self.subTest(key=key),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof,sources)
            dump(launch_path,original)
            child=report_path.parent/'current-long-image'/C.RAW_NAME
            value=json.loads(child.read_text());value['elapsedSeconds']=11.;dump(child,value)
            with self.assertRaisesRegex(ValueError,'raw child'):C.validate(report_path,SOURCE,proof,sources)
            value['elapsedSeconds']=10.;dump(child,value)
            target=sources/'Sources/PicShot/LiveScrollTextDependencies.swift';target.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError,'source bytes changed'):C.validate(report_path,SOURCE,proof,sources)

    def test_new_helper_signature_is_bound_to_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            child=report_path.parent/'current-long-image'/C.RAW_NAME
            value=json.loads(child.read_text());value['copyRetry']['helperMetrics'][0]['signature']['helperCDHash']='e'*40
            dump(child,value)
            for path in (report_path,report_path.parent/'text-script-demo.json'):
                wrapper=json.loads(path.read_text());wrapper['currentLongImage']=value;dump(path,wrapper)
            with self.assertRaisesRegex(ValueError,'runtime helper bound to package'):C.validate(report_path,SOURCE,proof,sources)

    def test_optional_identity_parameters_are_a_pair(self):
        for proof,root in ((Path('/unused'),None),(None,Path('/unused'))):
            with self.assertRaisesRegex(ValueError,'required together'):C.validate(Path('/unused'),SOURCE,proof,root)

    def test_source_and_png_alpha_corruption(self):
        for bad in (b'not a PNG',SOURCE_PNG[:-1],SOURCE_PNG+b'junk'):
            with self.assertRaises(ValueError):C.png(bad,'corrupt')
        translucent,_=T.T.png(2,2,(120,80,40,128))
        with self.assertRaisesRegex(ValueError,'not opaque'):C.png(translucent,'source')
        image=C.png(translucent,'UI',ui=True)
        self.assertEqual(image,(2,2,bytes((60,40,20,128))*4))

    def test_unsupported_png_semantics_and_crc_fail(self):
        tiny,_=T.T.png(2,2,(31,42,53,255))
        corrupt=bytearray(tiny);corrupt[-1]^=1
        with self.assertRaisesRegex(ValueError,'CRC'):C.png(bytes(corrupt),'CRC')
        for kind,payload in ((b'tRNS',b'\0'*6),(b'acTL',b'\0'*8),(b'ABCD',b'')):
            chunk=struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
            with self.subTest(kind=kind),self.assertRaises(ValueError):C.png(tiny[:33]+chunk+tiny[33:],'unsupported')
        header=bytearray(tiny[16:29]);header[8]=16
        modified=tiny[:16]+bytes(header)+struct.pack('>I',zlib.crc32(b'IHDR'+header)&0xffffffff)+tiny[33:]
        with self.assertRaisesRegex(ValueError,'unsupported PNG format'):C.png(modified,'depth')

    def test_duplicate_and_nonfinite_json_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/C.RAW_NAME
            for invalid in ('{"schemaVersion":1,"schemaVersion":1}', '{"elapsedSeconds":NaN}', '{"elapsedSeconds":Infinity}'):
                path.write_text(invalid)
                with self.subTest(json=invalid),self.assertRaises(ValueError):C.validate(path,SOURCE)

    def test_cli_normal_and_optimized(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for mode in ([],['-O']):
                good=subprocess.run([sys.executable,*mode,str(SCRIPTS/'check-live-scroll-text-script-demo.py'),'--report',str(report_path),'--source',SOURCE],capture_output=True,text=True)
                self.assertEqual(good.returncode,0,good.stderr)
                result=json.loads((report_path.parent/C.RECEIPT_NAME).read_text());self.assertFalse(result['installedIdentityBound'])
                bad=subprocess.run([sys.executable,*mode,str(SCRIPTS/'check-live-scroll-text-script-demo.py'),'--report',str(report_path),'--source','b'*40],capture_output=True,text=True)
                self.assertNotEqual(bad.returncode,0)


if __name__=='__main__':unittest.main()
