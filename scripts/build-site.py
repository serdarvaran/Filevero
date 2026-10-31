#!/usr/bin/env python3
"""Build both static language pages from the actual app catalog; no network or analytics."""

from pathlib import Path
import json, html, hashlib, re
from app_catalog import app_catalog

R = Path(__file__).resolve().parent.parent
css_revision = hashlib.sha256((R / 'docs/assets/site.css').read_bytes()).hexdigest()[:12]
app = app_catalog()
# The public catalog is regenerated from the app on every build so the format
# table, counts and playground cannot drift from `filevero-cli catalog`.
catalog = {
    'conversionMatrix': app['conversionMatrix'],
    'tools': [tool for tool in app['tools'] if tool in app['toolNames']],
}
(R / 'docs/assets/catalog.json').write_text(
    json.dumps(catalog, ensure_ascii=False, indent=2, separators=(',', ' : ')) + '\n'
)
routes_count = sum(len(v) for v in catalog['conversionMatrix'].values())
inputs_count = len(catalog['conversionMatrix'])
tools_count = len(catalog['tools'])
# The demo shows the Mac app, so Mac-only tables (camera RAW) join the shared ones.
def with_mac_only(shared, mac_only):
    return {ext: shared.get(ext, []) + mac_only.get(ext, []) for ext in shared.keys() | mac_only.keys()}


demo_catalog = {
    **catalog,
    'singleTools': with_mac_only(app['singleTools'], app['macOnlySingleTools']),
    'multipleTools': with_mac_only(app['multipleTools'], app['macOnlyMultipleTools']),
}
# UI copy and palette come from the shipping apps, just like the tool matrix.
# Keep marketing copy independent; the interactive preview follows native UI.
wheel_titles = app['toolNames']
editor_titles = app['editorTitles']
hints = app['editorHints']
primary = app['saveTitles']
palette = {
    key: {'light': light, 'dark': dark}
    for key, light, dark in re.findall(
        r'\("(\w+)","(#[A-Fa-f0-9]+)","(#[A-Fa-f0-9]+)"\)', (R / 'windows/Filevero.Windows/Theme.cs').read_text()
    )
}
translations = json.loads((R / 'Sources/FileveroCore/Resources/Turkish.json').read_text())
feedback = app['wheelFeedback']
ui_strings = (
    set(wheel_titles.values())
    | set(editor_titles.values())
    | set(hints.values())
    | set(primary.values())
    | {
        'Fine-tune it. Save a fresh copy.',
        'Convert',
        'Tools',
        'Actions',
        'Float',
        'Copy',
        'Move',
        'Copy Path',
        'Terminal',
        'Original stays safe',
        'PREVIEW',
        'MAKE IT YOURS',
        'Save a fresh copy',
        'Icons',
        'List',
        'Clear',
        'Close',
        'Appearance',
        'Light',
        'Dark',
    }
)
demo_catalog['presentation'] = {
    'wheelTitles': wheel_titles,
    'editorTitles': editor_titles,
    'hints': hints,
    'primaryTitles': primary,
    'palette': palette,
    'feedback': feedback,
    'translations': {text: translations[text] for text in sorted(ui_strings) if text in translations},
}
(R / 'docs/assets/demo/catalog.json').write_text(json.dumps(demo_catalog, ensure_ascii=False, separators=(',', ':')))
play_revision = hashlib.sha256(
    b''.join(
        (R / p).read_bytes()
        for p in [
            'docs/assets/playground.js',
            'docs/assets/playground.css',
            'docs/assets/wheel-geometry.mjs',
            'docs/assets/demo/catalog.json',
            'docs/assets/demo/wheel-selection.wav',
        ]
    )
).hexdigest()[:12]
features = [
    (
        'compress',
        'Compress',
        'Sıkıştır',
        'Image, video, audio and PDF compression. Choose quality, reduction percentage or target size where supported. An unreachable target returns an explanation rather than silently losing features.',
        'Görsel, video, ses ve PDF sıkıştırma. Desteklenen türlerde kalite, küçültme oranı veya hedef boyut seçilir; ulaşılamayan hedefler açıklanır.',
    ),
    (
        'removeMetadata',
        'Metadata',
        'Metadata',
        'Inspect, edit or remove supported image, PDF and media metadata, including track and chapter fields. Export a new copy.',
        'Desteklenen görsel, PDF ve medya metadatasını incele, düzenle veya kaldır. Track/chapter alanları dahil; yeni kopya oluşturulur.',
    ),
    (
        'editImage',
        'Edit image',
        'Görsel düzenle',
        'Resize, rotate, flip and tune brightness, contrast and saturation, with an original/result preview.',
        'Boyutlandır, döndür, yansıt; parlaklık, kontrast ve doygunluğu önizleyerek ayarla.',
    ),
    (
        'annotateImage',
        'Annotate',
        'İşaretle',
        'Independent freehand/marker and shape tools, text, arrows and Select / Move. Choose one drawing tool at a time.',
        'Bağımsız serbest çizim/marker ve şekiller, metin, oklar ve Select / Move. Her çizim aracı tek başına çalışır.',
    ),
    (
        'frameImage',
        'Frame image',
        'Çerçeve ekle',
        'Create a polished image frame with configurable padding, background, corners and shadow.',
        'Kenar boşluğu, arka plan, köşe ve gölge ayarlarıyla görsel çerçevesi oluştur.',
    ),
    (
        'cropImage',
        'Crop image',
        'Görseli kırp',
        'Drag to select, move or resize the crop. Hold Shift to lock its ratio; Return exports a cropped copy.',
        'Sürükleyerek alan seç, taşı veya boyutlandır. Shift oranı kilitler; Enter kırpılmış kopyayı kaydeder.',
    ),
    (
        'removeBackground',
        'Remove background',
        'Arka planı kaldır',
        'Automatically isolate the main subject and save a transparent PNG, on-device: Apple Vision on Mac, the open ISNet model with ONNX Runtime on Windows.',
        'Ana nesneyi otomatik ayıkla ve saydam PNG olarak kaydet; işlem aygıtta yapılır: Mac’te Apple Vision, Windows’ta ONNX Runtime ile açık ISNet modeli.',
    ),
    (
        'normalizeAudio',
        'Normalize audio',
        'Ses seviyesini eşitle',
        'Analyze loudness, then export with integrated-loudness, loudness-range and true-peak targets.',
        'Önce ses yüksekliği analiz edilir; hedef loudness, aralık ve true-peak değerleriyle kopya kaydedilir.',
    ),
    (
        'muteVideo',
        'Remove audio',
        'Video sesini kaldır',
        'Create a silent video copy while keeping the video stream.',
        'Video akışını koruyarak sessiz bir kopya oluştur.',
    ),
    (
        'trimVideo',
        'Trim video',
        'Video kırp',
        'Preview, drag In/Out handles, move the selection and export its range. Keyboard playback, seeking and I/O marks help refine cuts.',
        'Önizle, In/Out tutamaçlarını sürükle, seçimi taşı ve aralığı dışa aktar. Klavyeyle oynatma, gezinme ve I/O kesimi kolaylaştırır.',
    ),
    (
        'splitPDF',
        'Split PDF',
        'PDF böl',
        'Split selected pages into individual files or groups. Specify page ranges and pages per file.',
        'Sayfa aralıklarını ve dosya başına sayfa sayısını seçerek PDF’yi tek tek veya gruplar halinde böl.',
    ),
    (
        'organizePDF',
        'Organize PDF',
        'PDF düzenle',
        'Reorder, remove and rotate pages. Optional uniform-width output is limited when document features cannot be safely preserved.',
        'Sayfaları sırala, çıkar ve döndür. Eşit genişlik seçeneği, belge özelliklerinin güvenle korunabildiği dosyalarda kullanılır.',
    ),
    (
        'extractArchive',
        'Extract archives',
        'Arşiv aç',
        'Extract ZIP, TAR, GZIP and RAR into a new folder. Path and link validation keeps entries inside that folder.',
        'ZIP, TAR, GZIP ve RAR arşivlerini yeni klasöre çıkar. Yol ve link denetimleri klasör dışına yazmayı engeller.',
    ),
    (
        'createPDF',
        'Images to PDF',
        'Görsellerden PDF',
        'Combine selected images into a new PDF in the chosen order.',
        'Seçili görselleri istenen sırayla yeni bir PDF’de birleştir.',
    ),
    (
        'mergePDF',
        'Merge PDFs',
        'PDF birleştir',
        'Combine several PDFs while preserving supported page content and navigation. Originals remain unchanged.',
        'Birden fazla PDF’yi desteklenen sayfa içeriği ve gezinme özellikleri korunarak birleştir; orijinaller değişmez.',
    ),
    (
        'cropVideo',
        'Crop video',
        'Video alanını kırp',
        'Select a region directly on the video preview. Drag, resize, use Shift ratio lock and Return to export.',
        'Video önizlemesinde alan seç. Sürükle, boyutlandır; Shift ile oranı kilitle, Enter ile kopyayı dışa aktar.',
    ),
    (
        'changeVideoSpeed',
        'Change speed',
        'Video hızını değiştir',
        'Change video speed with matching audio tempo and preview controls.',
        'Önizleme kontrolleriyle video hızını ve buna eşlik eden ses temposunu değiştir.',
    ),
    (
        'joinVideos',
        'Join videos',
        'Videoları birleştir',
        'Join multiple clips in order, adapting geometry, frame rate and audio layout to a consistent output.',
        'Klipleri sırayla birleştir; boyut, kare hızı ve ses düzeni tutarlı bir çıktıya uyarlanır.',
    ),
    (
        'videoSnapshots',
        'Video snapshots',
        'Videodan kare al',
        'Choose timestamps and save still frames as new PNG files.',
        'Zaman noktalarını seçip kareleri yeni PNG dosyaları olarak kaydet.',
    ),
    (
        'splitVideo',
        'Split video',
        'Video böl',
        'Split at markers, equal clip counts or intervals. Remove unwanted segments; save separately or join retained clips.',
        'İşaretlerden, eşit klip sayısından veya aralıklardan böl. İstenmeyen parçaları çıkar; kalanları ayrı veya birleşik kaydet.',
    ),
    (
        'audioToVideo',
        'Audio to video',
        'Sesten video',
        'Create a waveform, spectrum, frequency-bar or still-image video from an audio file.',
        'Ses dosyasından waveform, spektrum, frekans çubukları veya sabit görselle video oluştur.',
    ),
    (
        'trimAudio',
        'Trim audio',
        'Ses kırp',
        'Waveform preview, In/Out handles and selected-range playback. Optional silence trimming and keyboard seeking.',
        'Waveform önizleme, In/Out tutamaçları ve seçili aralığı oynatma. İsteğe bağlı sessizlik kesme ve klavyeyle gezinme.',
    ),
    (
        'audioChannels',
        'Audio channels',
        'Ses kanalları',
        'Convert mono/stereo and set left/right levels, with channel previews.',
        'Mono/stereo dönüşümü yap, sol/sağ seviyelerini ayarla ve kanalları önizle.',
    ),
    (
        'createCollage',
        'Create collage',
        'Kolaj oluştur',
        'Arrange several images in a configurable layout with gaps and background styling.',
        'Birden fazla görseli aralık ve arka plan ayarlarıyla düzenlenebilir bir kolajda birleştir.',
    ),
    (
        'redactImage',
        'Redact image',
        'Görselde gizle',
        'Select areas and export with solid, blur or pixelation treatments. Always verify the resulting file before sharing.',
        'Alan seçip düz renk, blur veya pikselleştirme uygula. Paylaşmadan önce çıktıyı kontrol et.',
    ),
    (
        'redactVideo',
        'Redact video',
        'Videoda gizle',
        'Define rectangular regions and time ranges for solid, blur or pixelated redaction.',
        'Düz renk, blur veya pikselleştirme için dikdörtgen alanlar ve zaman aralıkları seç.',
    ),
    (
        'redactAudio',
        'Redact audio',
        'Seste gizle',
        'Choose intervals to replace with a bleep or silence; preserve the rest of the audio.',
        'Bleep veya sessizlikle değiştirilecek aralıkları seç; sesin geri kalanı korunur.',
    ),
    (
        'readQRCode',
        'Read QR codes',
        'QR kod oku',
        'Scan supported images and PDF pages, review detected contents and export a report.',
        'Desteklenen görsel ve PDF sayfalarını tara; bulunan içerikleri inceleyip rapor dışa aktar.',
    ),
]
assert set(x[0] for x in features) == set(catalog['tools'])
shortcuts = [
    ('⇧ + drag', 'Convert wheel', 'Dönüştürme çarkı'),
    ('⌘ + drag', 'Tools wheel', 'Araç çarkı'),
    ('⌃ + drag', 'File actions wheel', 'Dosya işlemleri çarkı'),
    ('⌃ ⇧ D', 'Download a copied web link', 'Kopyalanmış web linkini indir'),
    ('← ↑ / → ↓', 'Previous / next wheel item', 'Önceki / sonraki çark öğesi'),
    ('Home / End', 'First / last wheel item', 'İlk / son çark öğesi'),
    ('Enter / Space', 'Choose highlighted wheel item', 'Çarktaki seçili öğeyi uygula'),
    ('Esc / Tab', 'Close wheel', 'Çarkı kapat'),
    ('Space', 'Play / pause in supported media editors', 'Medya editörlerinde oynat / duraklat'),
    ('← / →', 'Seek backward / forward 1 second', '1 saniye geri / ileri git'),
    ('⇧ ← / ⇧ →', 'Video: 1 frame; audio: 0.1 second', 'Video: 1 kare; ses: 0,1 saniye'),
    ('I / O', 'Set selection In / Out', 'Seçimin In / Out noktasını belirle'),
    ('⇧ Space', 'Play the selected range', 'Seçili aralığı oynat'),
    ('M', 'Add a split marker where supported', 'Desteklenen araçlarda bölme işareti ekle'),
    ('Home / End', 'Go to beginning / end of preview', 'Önizlemenin başına / sonuna git'),
    ('⇧ + crop drag', 'Lock crop aspect ratio', 'Crop en-boy oranını kilitle'),
    ('Enter', 'Export crop in the crop editor', 'Crop editöründe kırpılmış kopyayı kaydet'),
    ('⌘ S', 'Save from supported editors', 'Desteklenen editörlerde kaydet'),
    ('⌘ ,', 'Open settings', 'Ayarları aç'),
    ('⌘ Q', 'Quit Filevero', 'Filevero’dan çık'),
]
E = html.escape


def showcase(assets, tr):
    choose = lambda en, tt: tt if tr else en
    shots = [
        (
            'mac-home.png',
            1600,
            1140,
            'Workspace',
            'Çalışma alanı',
            'Selected files on the left, every next step on the operation desk.',
            'Seçili dosyalar solda, sonraki her adım işlem masasında.',
        ),
        (
            'mac-wheel.png',
            640,
            640,
            'Tools wheel',
            'Araç çarkı',
            'Hold Command while dragging and pick a tool for the files in hand.',
            'Sürüklerken Command’a bas ve elindeki dosyalar için aracı seç.',
        ),
        (
            'mac-crop.png',
            1600,
            788,
            'Crop image',
            'Görsel kırp',
            'Drag a selection, lock its ratio and save a fresh copy.',
            'Alanı sürükleyerek seç, oranı kilitle ve yeni kopyayı kaydet.',
        ),
        (
            'mac-themes.png',
            1600,
            1295,
            'Eight themes',
            'Sekiz tema',
            'Aurora, Prism, Crystal and five more, in light or dark.',
            'Aurora, Prizma, Kristal ve beş tema daha; açık ya da koyu.',
        ),
        (
            'mac-home-dark.png',
            1600,
            1140,
            'Dark appearance',
            'Koyu görünüm',
            'The same glass workspace after sunset.',
            'Aynı cam çalışma alanı, gün batımından sonra.',
        ),
        (
            'mac-welcome.png',
            1600,
            1211,
            'First launch',
            'İlk açılış',
            'A short introduction that sets up tools and permissions.',
            'Araçları ve izinleri hazırlayan kısa bir tanıtım.',
        ),
    ]
    gallery = ''.join(
        f'<figure class="screenshot-card"><a href="{assets}showcase/{name}"><img src="{assets}showcase/{name}" alt="{E(choose(en,tt))}" loading="lazy" width="{w}" height="{h}"></a><figcaption><strong>{E(choose(en,tt))}</strong><span>{E(choose(desc,tdesc))}</span></figcaption></figure>'
        for name, w, h, en, tt, desc, tdesc in shots
    )
    return f'''<section id="demo" class="showcase">
<div class="section-heading"><span class="eyebrow">{choose('See it for yourself','Kendin gör')}</span><h2>{choose('Filevero, up close.','Filevero, yakından.')}</h2><p>{choose('Captures of the running Mac app with generated sample files.','Üretilmiş örnek dosyalarla çalışan Mac uygulamasından alınmış görüntüler.')}</p></div>
<div class="screenshot-grid">{gallery}</div>
<p class="subtle">{choose('Click any screenshot to see it in full.','Tam boyut için ekran görüntüsüne tıkla.')}</p>
</section>'''


for language in ['en', 'tr']:
    tr = language == 'tr'
    prefix = '../' if tr else ''
    assets = prefix + 'assets/'
    choose = lambda en, tt: tt if tr else en
    title = choose('Every file.<br><em>In the shape you need.</em>', 'Her dosya.<br><em>İhtiyacın olan biçimde.</em>')
    cards = ''.join(
        f'<article class="tool"><span class="tool-number">{i+1:02}</span><h3>{E(x[2] if tr else x[1])}</h3><p>{E(x[4] if tr else x[3])}</p><button class="try-tool" data-try-tool="{x[0]}">{choose("Try this tool","Bu aracı dene")} ↗</button></article>'
        for i, x in enumerate(features)
    )
    table = ''.join(
        '<tr><th scope="row">' + E(ext.upper()) + '</th><td>' + ', '.join(E(x.upper()) for x in dest) + '</td></tr>'
        for ext, dest in catalog['conversionMatrix'].items()
    )
    keys = ''.join(
        f'<tr><th scope="row"><kbd>{E(key)}</kbd></th><td>{E(tt if tr else en)}</td></tr>' for key, en, tt in shortcuts
    )
    doc = f'''<!doctype html>
<html lang="{language}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' blob: data:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' blob:; base-uri 'none'; form-action 'none'">
<meta name="description" content="{choose('Filevero: open-source local file conversion, editing, web downloads and a playful drag wheel. All features, formats and keyboard shortcuts.','Filevero: açık kaynaklı yerel dosya dönüştürme, düzenleme, web indirme ve sürükleme çarkı. Tüm özellikler, formatlar ve kısayollar.')}">
<title>Filevero — {choose('Every file, in the shape you need','Her dosya, ihtiyacın olan biçimde')}</title><link rel="icon" href="{assets}filevero.png"><link rel="stylesheet" href="{assets}site.css?v={css_revision}"><link rel="stylesheet" href="{assets}playground.css?v={play_revision}"><script src="{assets}vendor/pdf-lib.min.js" defer></script><script src="{assets}playground.js?v={play_revision}" defer></script></head>
<body><a class="skip" href="#main">{choose('Skip to content','İçeriğe geç')}</a><header><a class="brand" href="#"><img src="{assets}filevero.png" alt="" width="42" height="42">Filevero</a><nav aria-label="{choose('Main navigation','Ana gezinme')}"><a href="#playground">{choose("Try it","Dene")}</a><a href="#features">{choose('Features','Özellikler')}</a><a href="#formats">{choose('Formats','Formatlar')}</a><a href="#shortcuts">{choose('Shortcuts','Kısayollar')}</a><a href="{('../index.html' if tr else 'tr/index.html')}">{'EN' if tr else 'TR'}</a></nav></header>
<main id="main"><section class="hero"><span class="eyebrow">MAC + WINDOWS · {choose('FREE & OPEN SOURCE','ÜCRETSİZ & AÇIK KAYNAK')}</span><h1>{title}</h1><p class="intro">{choose('Drag a file. Tap a key. Make it yours. Convert, crop and fine-tune without breaking your flow.','Bir dosya sürükle. Bir tuşa bas. İstediğin hale getir. Dönüştür, kırp, düzenle; işine kaldığın yerden devam et.')}</p><div class="hero-actions"><a class="button primary" href="#download">{choose('Get Filevero','Filevero’yu indir')} ↓</a><a class="button secondary" href="#playground">{choose('Try in your browser','Tarayıcıda dene')} ↗</a></div><p class="subtle">{choose('Your files stay yours. Local processing. No subscription.','Dosyaların sende kalır. Yerel işlem. Abonelik yok.')}</p></section>
<section id="playground" aria-label="{choose('Interactive Filevero demo','Etkileşimli Filevero demosu')}"><div class="live-loading">{choose('Preparing your demo desktop…','Demo masaüstün hazırlanıyor…')}</div><noscript><p class="demo-noscript">{choose('Enable JavaScript to try the interactive playground. You can also watch the recording below.','Etkileşimli demo için JavaScript’i aç. Aşağıdaki gerçek kullanım kaydını da izleyebilirsin.')}</p></noscript></section>
<div class="demo-stats"><div><strong>{routes_count}</strong><span>{choose('conversion routes','dönüşüm yolu')}</span></div><div><strong>{tools_count}</strong><span>{choose('file tools','dosya aracı')}</span></div><div><strong>6</strong><span>{choose('ways to keep moving','dosya işlemi')}</span></div></div>

<section class="status" id="download"><div><span class="eyebrow">{choose('Download Filevero','Filevero’yu indir')}</span><h2>{choose('Ready for your files.','Dosyaların için hazır.')}</h2><p>{choose('Download the Mac (Apple Silicon) and Windows (x64) builds from <a href="https://github.com/serdarvaran/Filevero/releases/latest">GitHub Releases</a>, or build from <a href="https://github.com/serdarvaran/Filevero">source on GitHub</a>. After opening it, choose Finish setup → Download missing tools once for verified media and Office runtime downloads. Core native image and PDF features work immediately.','Mac (Apple Silicon) ve Windows (x64) sürümlerini <a href="https://github.com/serdarvaran/Filevero/releases/latest">GitHub Releases</a> sayfasından indir ya da <a href="https://github.com/serdarvaran/Filevero">GitHub’daki kaynak koddan</a> derle. Açtıktan sonra medya ve Office araçlarının doğrulanmış indirmeleri için bir kez Kurulumu tamamla → Eksik araçları indir’i seç. Temel yerel görsel ve PDF özellikleri hemen çalışır.')}</p><p class="subtle">{choose('Open the Mac disk image and drag Filevero onto Applications. Mac downloads are not notarized by Apple yet: after the first launch, choose Open Anyway in System Settings → Privacy &amp; Security. Windows builds are not Authenticode signed yet, so SmartScreen may ask you to confirm.','Mac disk görüntüsünü aç ve Filevero’yu Uygulamalar’ın üzerine sürükle. Mac indirmeleri henüz Apple tarafından notarize edilmedi: ilk açılıştan sonra Sistem Ayarları → Gizlilik ve Güvenlik’te Yine de Aç’ı seç. Windows sürümleri henüz Authenticode ile imzalı değil; SmartScreen onay isteyebilir.')}</p></div><div class="platforms"><div><strong>macOS</strong><span>Apple Silicon · macOS 13+</span><a class="button primary" href="https://github.com/serdarvaran/Filevero/releases/latest">{choose('Download .dmg','.dmg indir')}</a></div><div><strong>Windows</strong><span>x64 · {choose('Native preview','Yerel önizleme')}</span><a class="button secondary" href="https://github.com/serdarvaran/Filevero/releases/latest">{choose('Download .zip','.zip indir')}</a></div></div></section>
<section class="flow"><div class="section-heading"><span class="eyebrow">{choose('The everyday flow','Günlük kullanım')}</span><h2>{choose('One gesture. Many possibilities.','Tek hareket. Bir sürü olasılık.')}</h2></div><div class="flow-grid"><article><b>01</b><h3>{choose('Choose or drag','Seç veya sürükle')}</h3><p>{choose('Use Home or drag a file in Finder and hold Shift, Command or Control to open the matching wheel.','Ana ekrandan dosya seç veya Finder’da dosyayı sürüklerken Shift, Command ya da Control basılı tut.')}</p></article><article><b>02</b><h3>{choose('Make it yours','İstediğin hale getir')}</h3><p>{choose('Choose a format or tool. Preview edits and use keyboard controls for precise adjustments.','Formatı veya aracı seç. Düzenlemeyi önizle; hassas ayarlar için klavyeyi kullan.')}</p></article><article><b>03</b><h3>{choose('Save a fresh copy','Yeni kopyayı kaydet')}</h3><p>{choose('Watch real progress and save a new output. A short, borderless success card shows when it is ready.','Gerçek ilerlemeyi izle ve yeni çıktıyı kaydet. Tamamlandığında kısa, çerçevesiz bir bildirim görünür.')}</p></article></div></section>
<section class="flow"><div class="section-heading"><span class="eyebrow">{choose('Superpowers','Süper Yetenekler')}</span><h2>{choose('Built for creators, photographers and automators.','Üreticiler, fotoğrafçılar ve otomasyoncular için tasarlandı.')}</h2></div><div class="flow-grid"><article><b>01</b><h3>{choose('AI Background Removal','Yapay Zekayla Arka Plan Silme')}</h3><p>{choose('One-click subject lifting that stays on your computer: Apple Vision on Mac, the open ISNet model on Windows. Instant transparent PNG export.','Bilgisayarından çıkmayan tek tıkla nesne ayıklama: Mac’te Apple Vision, Windows’ta açık ISNet modeli. Anında saydam PNG.')}</p></article><article><b>02</b><h3>{choose('Social Media Presets','Sosyal Medya Şablonları')}</h3><p>{choose('One-tap exact ratios and pixel sizes for Instagram, YouTube, X, LinkedIn and web banners.','Instagram, YouTube, X, LinkedIn ve web bannerları için hazır en-boy oranları ve piksel boyutları.')}</p></article><article><b>03</b><h3>{choose('Menu Bar Drop Zone','Menü Çubuğu Drop Zone')}</h3><p>{choose('Drag any file straight onto the status bar icon to immediately reveal the radial conversion wheel.','Herhangi bir dosyayı menü çubuğu simgesine sürükleyerek radyal çarkı anında açın.')}</p></article><article><b>04</b><h3>{choose('Camera RAW Support','Kamera RAW Desteği')}</h3><p>{choose('Direct decoding and conversion for DNG, CR2, CR3, NEF, ARW, RW2 and ORF raw camera formats.','DNG, CR2, CR3, NEF, ARW, RW2 ve ORF kamera formatlarını doğrudan yerel motorla dönüştürün.')}</p></article><article><b>05</b><h3>{choose('macOS Shortcuts & Siri','macOS Kestirmeler & Siri')}</h3><p>{choose('Native AppIntents integration to convert, strip background, and compress files in Shortcuts.','Kestirmeler uygulamasıyla dosya dönüştürme, arka plan kaldırma ve sıkıştırma otomasyonu.')}</p></article></div></section>
<section id="features"><div class="section-heading"><span class="eyebrow">{choose('The Filevero toolbox','Filevero araç kutusu')}</span><h2>{tools_count} {choose('tools. Room to create.','araç. Üretmek için alan.')}</h2><p>{choose('The shared Mac and Windows tool catalog. Native platform details are listed below.','Mac ve Windows’un ortak araç kataloğu. Platforma özgü ayrıntılar aşağıda listelenir.')}</p></div><div class="tool-grid">{cards}</div></section>
<section id="windows" class="actions"><span class="eyebrow">Windows x64</span><h2>{choose('A native preview. A familiar flow.','Yerel bir önizleme. Tanıdık bir akış.')}</h2><div class="tool-grid"><article><h3>{choose('Images','Görseller')}</h3><p>{choose('PNG, JPG, BMP, GIF and TIFF conversion, with PDF export. Resize, crop, rotate, horizontal flip, independent marker/rectangle annotation, JPEG compression and metadata removal. GIF import uses its first frame.','PNG, JPG, BMP, GIF ve TIFF dönüşümü; PDF dışa aktarma. Boyutlandırma, crop, döndürme, yatay yansıtma, ayrı marker/dikdörtgen çizimi, JPEG sıkıştırma ve metadata kaldırma. GIF içe aktarma ilk kareyi kullanır.')}</p></article><article><h3>{choose('Media','Medya')}</h3><p>{choose('Video/audio conversion plus 15 tools: compression, metadata removal, loudness normalization, mute, video trim/crop/speed/join/snapshots/split/redaction, audio visualization, audio trim/channels/bleep. Export uses verified FFmpeg; native playback depends on Windows codecs.','Video/ses dönüşümü ve 15 araç: sıkıştırma, metadata kaldırma, loudness eşitleme, sessiz video; video trim/crop/hız/birleştirme/kare çıkarma/bölme/redaksiyon; ses görselleştirme, ses trim/kanallar/bleep. Dışa aktarma doğrulanmış FFmpeg kullanır; önizleme Windows codec’lerine bağlıdır.')}</p></article><article><h3>PDF & ZIP</h3><p>{choose('Merge PDFs, split pages and reorder selected page numbers. Create ZIPs from files and extract ZIPs with traversal/link checks, entry limits and expansion limits. Existing names are kept.','PDF birleştir, sayfaları böl ve seçili sayfa numaralarını sırala. Dosyalardan ZIP oluştur; yol/link, giriş sayısı ve açılmış boyut denetimleriyle ZIP çıkar. Mevcut dosyaların üzerine yazılmaz.')}</p></article><article><h3>{choose('The everyday controls','Günlük kontroller')}</h3><p>{choose('Mac-style Home and searchable Library, with System/Light/Dark appearance. Drop files or paste text, images and files with Ctrl+V. Ctrl+O chooses files; Ctrl+Space opens tools; Ctrl+2 opens Library; Ctrl+F searches. Clipboard imports and Library survive app updates. Space plays/pauses; Left/Right seek 1 second; I/O set a media range. Crop uses drag, Shift ratio lock and Enter. Escape closes the editor. Public-link video/audio/thumbnail downloads and signed public updates are included.','Mac tasarımında Home ve aranabilir Library; Sistem/Açık/Koyu görünüm. Dosya bırak veya Ctrl+V ile metin, görsel ve dosya yapıştır. Ctrl+O dosya seçer; Ctrl+Space çarkı açar; Ctrl+2 Library; Ctrl+F arama. Library ve yapıştırılan dosyalar güncellemede korunur. Space oynatır/duraklatır; sağ/sol ok 1 saniye gider; I/O medya aralığını belirler. Crop: sürükle, Shift ile oran kilidi, Enter ile kaydet. Escape editörü kapatır. Public linkten video/ses/thumbnail indirme ve imzalı public güncelleme vardır.')}</p></article></div><p>{choose('The Windows parity build adds Explorer drag wheels, Float, folder automation, Office/Pages conversion, QR reading, background removal and eight window layouts, including Maximize. AirDrop is replaced by Windows Share; system permissions, codecs and native dialogs follow each OS.','Windows eş özellik build’i Explorer sürükleme çarklarını, Float rafını, klasör otomasyonunu, Office/Pages dönüşümünü, QR okumayı, arka plan kaldırmayı ve Büyüt dahil sekiz pencere düzenini içerir. AirDrop yerine Windows Share kullanılır; sistem izinleri, codec’ler ve yerel pencereler işletim sistemine göre çalışır.')}</p></section>
<section class="web-feature"><span class="eyebrow">{choose('From the web to your workflow','Web’den iş akışına')}</span><h2>{choose('A link. A file. Yours to work with.','Bir link. Bir dosya. İşlemek sana kalmış.')}</h2><p>{choose('Paste a public video share link or direct media address. Choose video, MP3 or the original image/media, quality and destination. YouTube cards can offer video and thumbnail separately; Instagram reel cards need an actual reel link.','Public video paylaşım linkini veya doğrudan medya adresini yapıştır. Video, MP3 ya da orijinal görsel/medyayı; kaliteyi ve klasörü seç. YouTube kartlarında video ve thumbnail ayrı sunulabilir; Instagram reel kartlarında gerçek reel linki gerekir.')}</p><p>{choose('Use Control–Shift–D for a copied link, drag a browser card with Command, or drop it onto Home. Some players only expose a poster or blob address; Copy Share Link is the fallback. Supported sites change. Instagram photo posts open a photo picker; selected photos are saved in post order. Reels offer video and audio without a thumbnail action. DRM, live streams, login-required media, profile-wide downloads and video playlists are not supported.','Kopyalanmış link için Control–Shift–D kullan; tarayıcı kartını Command ile sürükle veya Ana ekrana bırak. Bazı oynatıcılar yalnızca poster/blob adresi verir; bu durumda paylaşım linkini kopyala. Site desteği değişebilir. Instagram fotoğraf gönderileri seçim listesi açar; seçilen görseller gönderi sırasıyla kaydedilir. Reels’te thumbnail seçeneği yoktur. DRM, canlı yayın, giriş gerektiren medya, tüm profil indirme ve video playlistleri desteklenmez.')}</p><button id="try-download" class="button secondary">{choose("Try the download flow","İndirme akışını dene")} ↗</button></section>
<section id="formats"><div class="section-heading"><span class="eyebrow">{choose('Formats, without the guesswork','Formatları açıkça gör')}</span><h2>{inputs_count} {choose('inputs.','girdi.')} {routes_count} {choose('routes.','dönüşüm yolu.')}</h2><p>{choose('This table is generated from the app catalog. A format appearing here does not mean every advanced document feature can be retained. PDF to DOCX/XLSX reconstruction is heuristic; PDF to PPTX uses page images.','Bu tablo uygulama kataloğundan üretilir. Bir formatın listelenmesi, her gelişmiş belge özelliğinin korunabildiği anlamına gelmez. PDF→DOCX/XLSX yeniden kurma sezgiseldir; PDF→PPTX sayfa görselleri kullanır.')}</p></div><label class="search-label" for="format-search">{choose('Find an input or output format','Girdi veya çıktı formatı ara')}</label><input id="format-search" type="search" placeholder="PNG, MP4, PDF…" autocomplete="off"><div class="table-wrap"><table id="format-table"><thead><tr><th>{choose('Input','Girdi')}</th><th>{choose('Available outputs','Çıktılar')}</th></tr></thead><tbody>{table}</tbody></table></div></section>
<section class="actions"><h2>{choose('Six ways to keep files moving.','Dosyaları ilerletmenin altı yolu.')}</h2><div class="action-list">{''.join('<span>'+E(v)+'</span>' for v in (['AirDrop','Float','Copy','Move','Copy path','Open in Terminal'] if not tr else ['AirDrop','Float rafı','Kopyala','Taşı','Yolu kopyala','Terminal’de aç']))}</div><p>{choose('Float keeps files in a small shelf. History can be searched, reused and revealed in Finder. Move explicitly moves originals; exports create new copies and do not overwrite existing names.','Float dosyaları küçük bir rafta tutar. Geçmişte ara, dosyaları yeniden kullan veya Finder’da göster. Taşı işlemi orijinali taşır; dışa aktarımlar yeni kopya oluşturur ve mevcut adların üzerine yazmaz.')}</p></section>
<section id="shortcuts"><div class="section-heading"><span class="eyebrow">{choose('Keep your hands in flow','Elin alışsın, işin hızlansın')}</span><h2>{choose('The shortcut sheet.','Kısayol rehberi.')}</h2><p>{choose('macOS defaults. Drag modifiers are customizable. Editor shortcuts apply where that action is available; text fields and native controls retain their normal input behavior.','macOS varsayılanları. Sürükleme tuşları özelleştirilebilir. Editör kısayolları ilgili işlem destekleniyorsa çalışır; metin alanları ve yerel kontroller normal davranışını korur.')}</p></div><div class="table-wrap"><table><thead><tr><th>{choose('Shortcut','Kısayol')}</th><th>{choose('Action','İşlem')}</th></tr></thead><tbody>{keys}</tbody></table></div></section>
{showcase(assets,tr)}
<section class="trust"><div><span class="eyebrow">{choose('Local first. Open by design.','Önce yerel. Tasarımı açık.')}</span><h2>{choose('Small footprint.<br>Clear boundaries.','Küçük araç.<br>Açık sınırlar.')}</h2></div><div><h3>{choose('Privacy','Gizlilik')}</h3><p>{choose('Conversion and editing run locally. Web downloads contact the chosen site. No analytics, cloud account, browser-cookie import or subscription is built in.','Dönüştürme ve düzenleme yerelde çalışır. Web indirmeleri seçilen siteye bağlanır. Analytics, bulut hesabı, tarayıcı çerezi aktarma veya abonelik bulunmaz.')}</p><h3>{choose('Signed updates','İmzalı güncellemeler')}</h3><p>{choose('Updates are verified before they replace anything: macOS checks its signed feed and archive, Windows its archive signature and version. Both apps check GitHub Releases, then install a verified update and restart themselves.','Güncellemeler bir şeyi değiştirmeden önce doğrulanır: macOS imzalı akışı ve arşivi, Windows arşiv imzasını ve sürümü denetler. İki uygulama da GitHub Releases’i denetler, doğrulanmış güncellemeyi kurar ve kendini yeniden başlatır.')}</p><h3>{choose('Transparent limitations','Açık sınırlamalar')}</h3><p>{choose('Complex document conversions are best-effort. Haptic feedback depends on hardware. macOS and Windows may show first-run warnings for builds without an OS-trusted publisher signature. We do not ask you to disable system security.','Karmaşık belge dönüşümleri her özelliği koruyamayabilir. Titreşim donanıma bağlıdır. İşletim sistemince güvenilen yayıncı imzası olmayan build’lerde macOS/Windows ilk açılış uyarıları gösterebilir. Sistem güvenliğini kapatmanız istenmez.')}</p></div></section>
<section class="inspiration"><h2>{choose('Inspired. Independently made.','İlham alındı. Özgün olarak geliştirildi.')}</h2><p>{choose('Filevero is an original application inspired by Tangerine’s delightful drag-and-wheel interaction, featuring refined workflows and extensive capabilities. It is not affiliated with or endorsed by Tangerine or LEAP STUDIO.','Filevero, Tangerine adlı uygulamanın keyifli sürükle ve çark etkileşiminden ilham alınarak geliştirilmiş özgün bir uygulamadır; yeni özellikler ve modern iş akışları sunar. Tangerine veya LEAP STUDIO ile herhangi bir bağlantısı yoktur ve onlar tarafından desteklenmez.')}</p><a href="https://tangerineformac.com/">Tangerine ↗</a></section></main>
<footer><a class="brand" href="#">Filevero <span>◉</span></a><p>{choose('Every file, in the shape you need. Source under MIT; third-party tools keep their own licenses.','Her dosya, ihtiyacın olan biçimde. Kaynak kod MIT lisanslıdır; üçüncü taraf araçların kendi lisansları geçerlidir.')}</p></footer></body></html>'''
    out = R / 'docs' / ('tr/index.html' if tr else 'index.html')
    out.write_text(doc)
print(f'Built EN/TR pages and interactive catalog: {len(features)} tools, {inputs_count} inputs, {routes_count} routes, {len(shortcuts)} shortcuts each')
