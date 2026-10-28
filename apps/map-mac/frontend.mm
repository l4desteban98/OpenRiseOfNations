// The front end (docs/ui-port.md "Front end"). The original's pieces it reproduces (decompiled in re/decomp/frontend):
//   - TopMenu::on_redraw @0059c100: the BACKGROUND window's ANIM list (topmenu.xml) - each layer a full-screen quad of
//     its 1280x720 texture, shifted by (move * t + start_offset) * screen size, drawn in IFACETEXLOAD sort order with
//     render type 7; the whole picture fades in from black between 0.5 and 1.5 s and out over the last second of the
//     animation's duration, then the next animation starts (all four cycle). static_bg_tex (iface_wrapper1.tga) when
//     there are no animations.
//   - TopMenu::draw_logo @0059cff0: the EE logo is a quad of ron_logo_texture_map.tga lit through
//     ron_logo_normal_map.tga by a light whose direction follows the mouse around the logo's centre
//     (dir = normalize(k * unit(centre - mouse), -1), k = |logo size| / screen width). Wrapper_Main_Logo_01.tga is the
//     flat fallback the original uses on weak GPUs.
//   - TopMenuSelection::on_redraw @0059ee80 / on_button_redraw @0059eac0: the title ribbon (3-slice expander into
//     IFACERECT title, Georgia 22 white with a black shadow), the bronze IFACEBORDER "border" around the window below
//     the ribbon (top + title height), buttons from button_left / button_mid (tiled) / button_right at their 37 px
//     height: the atlas row one piece-height up when hovered / focused / pressed, one down when disabled; caption
//     font 18, white with a (64,64,64) shadow, centred, moved (+2, +2) when enabled. The window is sized around its
//     buttons with 41 px margins (TopMenuSelection::exec).
//   - TopMenu::on_window_redraw @0059cd20: the help text of the hovered button, font 16, white.
// The screens, their copy and their placement follow the user's design (Menus.dc.html); the controls the original
// draws in code (combo box, list, popup) use the install's GAMESPYREJOIN combo / large-button / edit-border pieces,
// SCROLLCLASS and POPUPSTYLE default.
#import "frontend.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "assets/cursors.hpp"
#include "assets/iface_layout.hpp"
#include "assets/tga.hpp"
#include "assets/xml.hpp"
#include "audio.hpp"
#include "renderer.hpp"
#include "ui.hpp"
#import "launcher.h"

namespace {

namespace rm = ron::metal;
using ron::IfacePiece;
using ron::IfaceRect;
using rm::argb;
using rm::rgb;
using rm::UiType;

constexpr int kW = 1024, kH = 768;  // the design canvas (the front end's 1024 x 768 backgrounds)
constexpr uint32_t kWhite = 0xFFFFFFFF, kBlack = 0xFF000000;
const uint32_t kLabel = rgb(212, 212, 212), kSecondary = rgb(189, 205, 216), kButtonShadow = rgb(64, 64, 64);

const char* const kDifficulty[6] = {"Easiest", "Easy", "Moderate", "Tough", "Tougher", "Toughest"};
struct MainItem {
	const char* label;
	const char* help;
	bool enabled;
};
const MainItem kMainItems[5] = {
    {"Tutorials", "Learn to play, step by step. Start with Tutorial 1.", true},
    {"Skirmish", "Battle computer opponents on a ready-made map.", true},
    {"Scenarios", "Chess exercises and the battle maps of the Conquer the World campaigns.", true},
    {"Multiplayer", "Not available yet.", false},
    {"Quit", "Leave Rise of Nations and return to the desktop.", true},
};

enum Screen { kMain = 0, kTutorials, kSkirmish, kScenarios };
const char* const kScreenNames[4] = {"main", "tutorials", "skirmish", "scenarios"};
const char* const kListTitles[4] = {"Main Menu", "Tutorials", "Skirmish", "Scenarios"};
const char* const kListNotes[4] = {
    "",
    "Start with Tutorial 1. The tutorials guide you with voice-overs, arrows and objectives.",
    ("Choose a map, then Play to configure civilizations, computer opponents, teams and rules. "
     "Uses existing starting positions; random maps are not available yet."),
    "Chess exercises and the battle maps of the Conquer the World campaigns.",
};

// Hit-test ids.
enum : int {
	kNone = -1,
	kMainBtn = 0,  // + item
	kChange = 10,
	kBack = 11,
	kPlay = 12,
	kDrop = 13,
	kDropItem = 20,  // + difficulty
	kScrollUp = 30,
	kScrollDown = 31,
	kThumb = 32,
	kTrack = 33,
	kPopupBtn = 40,  // + button
	kRow = 100,      // + entry
};

struct AnimLayer {
	IfacePiece piece;
	float move_x = 0, move_y = 0, off_x = 0, off_y = 0;
	int sort = 0;
};
struct Anim {
	float duration = 30;
	std::vector<AnimLayer> layers;  // in draw order (IFACETEXLOAD sort, as flush_all submits the packets)
};

constexpr int kRowH = 40;

struct Layout {
	IfaceRect title, title_text, frame;
	std::vector<IfaceRect> buttons;
	IfaceRect info, edit, change;
	int folder_y = 0, label_x = 0;
	IfaceRect list_frame, list, scroll, up, down, track, thumb;
	IfaceRect drop, back, play;
	std::vector<IfaceRect> drop_items;
	int note_y = 0;
	int rows = 0;
};

const char* kLogoShader = R"(
#include <metal_stdlib>
using namespace metal;
struct LogoV { float4 pos [[position]]; float2 uv; };
struct LogoQuad { float4 rect; float4 view; float4 light; };  // rect x, y, w, h (UI px); view w, h; light xyz, flip
vertex LogoV logo_vertex(uint vid [[vertex_id]], constant LogoQuad& q [[buffer(0)]]) {
	const float2 c[4] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
	float2 p = q.rect.xy + c[vid] * q.rect.zw;
	LogoV o;
	o.pos = float4(p.x / q.view.x * 2.0 - 1.0, 1.0 - p.y / q.view.y * 2.0, 0.0, 1.0);
	o.uv = c[vid];
	return o;
}
fragment float4 logo_fragment(LogoV in [[stage_in]], texture2d<float> diffuse [[texture(0)]], texture2d<float> normals [[texture(1)]],
                              sampler s [[sampler(0)]], constant LogoQuad& q [[buffer(0)]]) {
	float4 c = diffuse.sample(s, in.uv);
	float3 n = normals.sample(s, in.uv).xyz * 2.0 - 1.0;
	n.y *= q.light.w;
	n = normalize(n);
	float ndl = max(dot(n, normalize(q.light.xyz)), 0.0);
	float3 h = normalize(normalize(q.light.xyz) + float3(0, 0, 1));
	float spec = pow(max(dot(n, h), 0.0), 24.0) * 0.35;
	return float4(saturate(c.rgb * (0.42 + 0.78 * ndl) + spec * c.a), c.a);
}
// The project's main-menu logo (premultiplied PNG): light.x = 0 draws its soft drop shadow (the alpha of a coarse mip,
// black at 60 %), 1 the image.
fragment float4 image_fragment(LogoV in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                               constant LogoQuad& q [[buffer(0)]]) {
	if (q.light.x < 0.5) return float4(0, 0, 0, t.sample(s, in.uv, level(q.light.y)).a * 0.6);
	return t.sample(s, in.uv);
}
)";

std::vector<std::string> wrap_text(rm::UiRenderer& ui, int f, const std::string& text, int width) {
	std::vector<std::string> lines;
	std::string line, word;
	auto flush_word = [&]() {
		if (word.empty()) return;
		const std::string cand = line.empty() ? word : line + " " + word;
		if (!line.empty() && ui.text_width(f, cand) > width) {
			lines.push_back(line);
			line = word;
		} else {
			line = cand;
		}
		word.clear();
	};
	for (char ch : text) {
		if (ch == ' ') flush_word();
		else word += ch;
	}
	flush_word();
	if (!line.empty()) lines.push_back(line);
	return lines;
}

}  // namespace

NSCursor* ron_game_cursor(const ron::GameFiles& files, int cid) {
	static std::vector<ron::CursorRow> rows;
	static std::string rows_root;
	if (rows_root != files.root()) rows = ron::load_cursors(files), rows_root = files.root();
	if (cid < 0 || size_t(cid) >= rows.size()) return [NSCursor arrowCursor];
	const ron::CursorRow& r = rows[size_t(cid)];
	try {
		const ron::Image img = ron::parse_tga(ron::read_file(files.resolve(r.file)));
		NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:r.xs pixelsHigh:r.ys bitsPerSample:8
		                                                         samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		                                                          colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:r.xs * 4 bitsPerPixel:32];
		for (int y = 0; y < r.ys; y++) {
			for (int x = 0; x < r.xs; x++) {
				const int sx = r.x + x, sy = r.y + y;
				uint8_t* d = rep.bitmapData + (y * r.xs + x) * 4;
				if (sx < img.width && sy < img.height) std::memcpy(d, &img.rgba[size_t(sy * img.width + sx) * 4], 4);
				else std::memset(d, 0, 4);
			}
		}
		NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(r.xs, r.ys)];
		[image addRepresentation:rep];
		return [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(r.hot_x, r.hot_y)];
	} catch (const std::exception&) {
		return [NSCursor arrowCursor];
	}
}

@implementation FrontEnd {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	NSString* _dir;
	std::unique_ptr<ron::GameFiles> _files;
	std::unique_ptr<ron::IfaceLayout> _iface, _top;
	rm::UiRenderer _ui;
	// topmenu.xml / interface.xml pieces
	std::vector<Anim> _anims;
	IfacePiece _staticBg, _flatLogo;
	IfacePiece _btn[3], _ribbon[3];
	ron::IfaceBorder _border, _thin;
	IfaceRect _titleRect, _titleText;
	IfaceRect _btnRect;  // first MAINMENU button, window-relative
	int _btnInc;
	IfacePiece _popBtn[3][3];  // normal, highlight, down x 3 slices
	uint32_t _popBg;
	IfacePiece _combo[4], _large[3];
	IfacePiece _scrollUp, _scrollDown, _scrollBack[3], _scrollSlider[3];
	// the bump-mapped logo
	id<MTLRenderPipelineState> _logoPipe;
	id<MTLSamplerState> _logoSampler;
	id<MTLTexture> _logoTex, _logoNormal;
	id<MTLRenderPipelineState> _imagePipe;
	id<MTLTexture> _menuLogo;  // apps/map-mac/resources/menu-logo.png (the app bundle's Resources when packaged)
	// state
	Screen _screen;
	std::vector<launcher::Entry> _entries;
	int _sel, _top0;  // selected entry, first visible row
	int _difficulty;
	int _focus;       // main menu: keyboard focus (button index)
	int _hover, _pressed;
	BOOL _dropOpen;
	BOOL _dragThumb;
	int _dragOffset;
	std::string _help;
	struct Popup {
		bool open = false;
		int kind = 0;  // 0 quit, 1 error, 2 busy
		std::string text;
		std::vector<std::string> buttons;
		std::vector<IfaceRect> rects;
	} _popup;
	// animation / time
	int _anim;
	double _animT, _timeMs, _lastFrame;
	BOOL _interactive;
	std::unique_ptr<ron::audio::Audio> _audio;
	std::vector<std::pair<std::string, std::vector<std::string>>> _soundGlobals;
	std::vector<std::pair<std::string, std::string>> _soundFiles;
	// view mapping (set every frame)
	float _fit;          // points per canvas pixel
	int _uiW, _uiH;      // the window in canvas pixels
	int _ox, _oy;        // the canvas origin in the window
	CGPoint _mouse;      // canvas pixels
	BOOL _mouseKnown;
	double _lastClickMs;
	int _lastClickRow;
	NSCursor* _cursor;
}

- (NSString*)gameDir {
	return _dir;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device gameDir:(NSString*)dir error:(NSString* __autoreleasing*)error {
	if (!(self = [super init])) return nil;
	_device = device;
	_queue = [device newCommandQueue];
	_dir = dir;
	_fit = 1, _uiW = kW, _uiH = kH;
	_hover = _pressed = kNone;
	_lastClickRow = -1;
	std::string err;
	try {
		_files = std::make_unique<ron::GameFiles>(dir.UTF8String);
		_iface = std::make_unique<ron::IfaceLayout>(_files->read_text("Data/interface.xml"));
		_top = std::make_unique<ron::IfaceLayout>(_files->read_text("Data/topmenu.xml"));
	} catch (const std::exception& e) {
		if (error) *error = [NSString stringWithFormat:@"Could not read the game's menu data: %s", e.what()];
		return nil;
	}
	if (!_ui.init(device, _queue, MTLPixelFormatBGRA8Unorm, _files.get(), _iface.get(), err)) {
		if (error) *error = @(err.c_str());
		return nil;
	}
	// topmenu.xml's atlas ids (TEX_TOPMENU_0, TEX_WRAPPER_LOGO, ANIM_*, TEX_WRAPPER_4) next to interface.xml's.
	std::map<std::string, int> sort_of;
	ron::for_each_element(_top->root(), "IFACETEXLOAD", [&](const ron::XmlElement& e) {
		const std::string id = ron::iface_attr(e, "id");
		if (!sort_of.count(id)) sort_of[id] = ron::iface_int(ron::iface_attr(e, "sort"));
	});
	for (const auto& [id, file] : _top->texloads()) _ui.add_texload(id, file);

	const ron::XmlElement* bg = _top->find("BACKGROUND");
	const ron::XmlElement* sel = _top->find("topmenuselection");
	const ron::XmlElement* mm = _top->find("MAINMENU");
	if (!bg || !sel || !mm) {
		if (error) *error = @"Data/topmenu.xml lacks the TopMenu windows";
		return nil;
	}
	for (const ron::XmlElement& a : bg->children) {
		if (!ron::iface_tag_is(a, "ANIM")) continue;
		Anim an;
		an.duration = a.get_float("duration", 30);
		for (const ron::XmlElement& l : a.children) {
			if (!ron::iface_tag_is(l, "ANIMLAYER")) continue;
			AnimLayer layer;
			layer.piece = ron::iface_find_piece(*bg, ron::iface_attr(l, "texture"));
			layer.move_x = l.get_float("move_x"), layer.move_y = l.get_float("move_y");
			layer.off_x = l.get_float("start_offset_x"), layer.off_y = l.get_float("start_offset_y");
			layer.sort = sort_of.count(layer.piece.texture) ? sort_of[layer.piece.texture] : 0;
			if (layer.piece.valid() && !_files->resolve(_top->texload_file(layer.piece.texture)).empty()) an.layers.push_back(layer);
		}
		std::stable_sort(an.layers.begin(), an.layers.end(), [](const AnimLayer& x, const AnimLayer& y) { return x.sort < y.sort; });
		if (!an.layers.empty() && an.duration > 0) _anims.push_back(an);
	}
	_staticBg = ron::iface_find_piece(*bg, "static_bg_tex");
	_flatLogo = ron::iface_find_piece(*bg, "logo");
	_thin = ron::iface_find_border(*bg, "motd_border");
	_btn[0] = ron::iface_find_piece(*sel, "button_left");
	_btn[1] = ron::iface_find_piece(*sel, "button_mid");
	_btn[2] = ron::iface_find_piece(*sel, "button_right");
	for (int k = 0; k < 3; k++) _ribbon[k] = ron::iface_find_piece(*sel, "ribbon", k);
	_border = ron::iface_find_border(*sel, "border");
	ron::iface_find_rect(*sel, "IFACERECT", "title", kW, kH, _titleRect);
	ron::iface_find_rect(*sel, "IFACERECT", "title_text", kW, kH, _titleText);
	const auto kids = ron::iface_layout_children(*mm, 548, 768);
	_btnRect = kids.empty() ? IfaceRect{41, 495, 114, 149} : kids[0].rect;
	_btnInc = kids.size() > 1 ? kids[1].rect.t - kids[0].rect.t : 36;
	// interface.xml: POPUPSTYLE default, the GameSpy dialog's combo box / large buttons, SCROLLCLASS.
	_popBg = argb(224, 39, 40, 43);
	if (const ron::XmlElement* pop = _iface->find("POPUP")) {
		for (const ron::XmlElement& st : pop->children) {
			if (!ron::iface_tag_is(st, "POPUPSTYLE") || ron::iface_attr(st, "name") != "default") continue;
			const char* kinds[3] = {"butnormal", "buthighlight", "butdown"};
			for (int s = 0; s < 3; s++) {
				for (int k = 0; k < 3; k++) _popBtn[s][k] = ron::iface_find_piece(st, std::string(kinds[s]) + std::to_string(k));
			}
			if (const ron::XmlElement* c = ron::iface_child(st, "IFACECOLOR", "bg_color")) _popBg = ron::iface_color(*c);
		}
	}
	if (const ron::XmlElement* gs = _iface->find("gamespyrejoin")) {
		const char* names[4] = {"combo_left", "combo_mid", "combo_right", "combo_arrow"};
		for (int k = 0; k < 4; k++) _combo[k] = ron::iface_find_piece(*gs, names[k]);
		for (int k = 0; k < 3; k++) _large[k] = ron::iface_find_piece(*gs, "large_button" + std::to_string(k));
	}
	if (const ron::XmlElement* sc = _iface->find("SCROLLCLASS")) {
		_scrollUp = ron::iface_find_piece(*sc, "button_up");
		_scrollDown = ron::iface_find_piece(*sc, "button_down");
		for (int k = 0; k < 3; k++) _scrollBack[k] = ron::iface_find_piece(*sc, "back_vert", k);
		for (int k = 0; k < 3; k++) _scrollSlider[k] = ron::iface_find_piece(*sc, "slider_vert", k);
	}
	[self loadLogo:_top->find("LOGO")];
	[self loadMenuLogo];
	// Sounds: soundglobals KEY -> soundfiles tag -> file (SoundGlobal::play).
	try {
		const ron::XmlElement sg = ron::parse_xml(_files->read_text("Data/soundglobals.xml"));
		ron::for_each_element(sg, "GLOBAL", [&](const ron::XmlElement& e) {
			const ron::XmlElement* k = e.child("KEY");
			if (!k) return;
			std::vector<std::string> tags;
			for (const ron::XmlElement& c : e.children) {
				if (c.name == "SOUND") tags.push_back(ron::to_lower(c.get("#text")));
			}
			_soundGlobals.push_back({k->get("#text"), tags});
		});
		const ron::XmlElement sf = ron::parse_xml(_files->read_text("Data/soundfiles.xml"));
		ron::for_each_element(sf, "SOUNDFILE", [&](const ron::XmlElement& e) {
			_soundFiles.push_back({ron::to_lower(e.get("tag")), ron::normalize_game_path(e.get("file"))});
		});
	} catch (const std::exception& e) {
		std::fprintf(stderr, "menu sounds: %s\n", e.what());
	}
	NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
	_difficulty = [d objectForKey:launcher::kDefDifficulty] ? int(std::clamp<NSInteger>([d integerForKey:launcher::kDefDifficulty], 0, 5)) : 2;
	_help = kMainItems[0].help;
	_animT = 0;
	if (const char* a = getenv("RON_MENU_ANIM")) {  // "N,T": animation N at T seconds (snapshot checks)
		std::sscanf(a, "%d,%lf", &_anim, &_animT);
		_anim = _anims.empty() ? 0 : std::clamp(_anim, 0, int(_anims.size()) - 1);
	} else {
		_animT = 6.0;  // headless renders show the picture after its fade-in; startInteractive restarts it
	}
	_mouse = CGPointMake(300, 250);  // a light from the menu side until the mouse moves
	[self showScreen:@(kScreenNames[0])];
	return self;
}

- (id<MTLTexture>)textureFromFile:(const std::string&)rel {
	const std::string path = _files->resolve(rel);
	if (path.empty()) return nil;
	try {
		const ron::Image img = ron::parse_tga(ron::read_file(path));
		MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                                             width:NSUInteger(img.width)
		                                                                            height:NSUInteger(img.height)
		                                                                         mipmapped:YES];
		d.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> t = [_device newTextureWithDescriptor:d];
		[t replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(img.width), NSUInteger(img.height)) mipmapLevel:0 withBytes:img.rgba.data()
		     bytesPerRow:NSUInteger(img.width) * 4];
		id<MTLCommandBuffer> cb = [_queue commandBuffer];
		id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		[b generateMipmapsForTexture:t];
		[b endEncoding];
		[cb commit];
		return t;
	} catch (const std::exception& e) {
		std::fprintf(stderr, "menu texture %s: %s\n", rel.c_str(), e.what());
		return nil;
	}
}

// topmenu.xml LOGO: LOGODIFFUSE texture + normalmap (TopMenu::init_logo).
- (void)loadLogo:(const ron::XmlElement*)logo {
	if (getenv("RON_FLAT_LOGO")) return;
	const ron::XmlElement* dif = logo ? logo->child("LOGODIFFUSE") : nullptr;
	if (!dif) return;
	_logoTex = [self textureFromFile:ron::normalize_game_path(dif->get("texture"))];
	_logoNormal = [self textureFromFile:ron::normalize_game_path(dif->get("normalmap"))];
	if (!_logoTex || !_logoNormal) {
		_logoTex = _logoNormal = nil;
		return;
	}
	NSError* err = nil;
	id<MTLLibrary> lib = [_device newLibraryWithSource:@(kLogoShader) options:nil error:&err];
	MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"logo_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"logo_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
	_logoPipe = lib ? [_device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
	if (!_logoPipe) {
		std::fprintf(stderr, "logo shader: %s\n", err.localizedDescription.UTF8String);
		_logoTex = _logoNormal = nil;
		return;
	}
	MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterLinear;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	_logoSampler = [_device newSamplerStateWithDescriptor:sd];
}

// The main-menu logo the project ships (the user's adaptation of the EE logo): Contents/Resources in the app, else
// apps/map-mac/resources next to a dev build (build/ronmap) or this source file. Missing: the install's logo.
- (void)loadMenuLogo {
	if (getenv("RON_INSTALL_LOGO")) return;
	NSMutableArray<NSString*>* paths = [NSMutableArray array];
	if (NSString* p = [NSBundle.mainBundle pathForResource:@"menu-logo" ofType:@"png"]) [paths addObject:p];
	NSString* exeDir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
	if (exeDir) {
		[paths addObject:[exeDir stringByAppendingPathComponent:@"../Resources/menu-logo.png"]];
		[paths addObject:[exeDir stringByAppendingPathComponent:@"../apps/map-mac/resources/menu-logo.png"]];
		[paths addObject:[exeDir stringByAppendingPathComponent:@"resources/menu-logo.png"]];
	}
	[paths addObject:[@(__FILE__).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"resources/menu-logo.png"]];
	NSBitmapImageRep* rep = nil;
	for (NSString* p in paths) {
		NSData* data = [NSData dataWithContentsOfFile:p.stringByStandardizingPath];
		if (data && (rep = [NSBitmapImageRep imageRepWithData:data])) break;
	}
	CGImageRef img = rep.CGImage;
	if (!img) return;
	if (!_logoSampler) {
		MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.mipFilter = MTLSamplerMipFilterLinear;
		sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
		_logoSampler = [_device newSamplerStateWithDescriptor:sd];
	}
	const size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
	std::vector<uint8_t> px(w * h * 4);
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(cs);
	if (!ctx) return;
	CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(w), CGFloat(h)), img);
	CGContextRelease(ctx);
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:YES];
	d.usage = MTLTextureUsageShaderRead;
	_menuLogo = [_device newTextureWithDescriptor:d];
	[_menuLogo replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px.data() bytesPerRow:w * 4];
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b generateMipmapsForTexture:_menuLogo];
	[b endEncoding];
	[cb commit];
	NSError* err = nil;
	id<MTLLibrary> lib = [_device newLibraryWithSource:@(kLogoShader) options:nil error:&err];
	MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"logo_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"image_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;  // premultiplied
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
	_imagePipe = lib ? [_device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
	if (!_imagePipe) {
		std::fprintf(stderr, "menu logo shader: %s\n", err.localizedDescription.UTF8String);
		_menuLogo = nil;
	}
}

// ---------------------------------------------------------------- state

- (void)showScreen:(NSString*)name {
	_popup = Popup{};
	_dropOpen = NO;
	_hover = _pressed = kNone;
	if ([name isEqualToString:@"quit-popup"]) {
		[self showScreen:@"main"];
		[self openQuitPopup];
		return;
	}
	Screen s = kMain;
	for (int i = 0; i < 4; i++) {
		if ([name isEqualToString:@(kScreenNames[i])]) s = Screen(i);
	}
	_screen = s;
	_sel = 0, _top0 = 0, _focus = 0;
	_entries.clear();
	if (s != kMain) {
		_entries = launcher::entries_for(s == kTutorials ? launcher::Mode::Tutorials : s == kSkirmish ? launcher::Mode::Skirmish
		                                                                                              : launcher::Mode::Scenarios,
		                                 _dir);
		NSString* key = [NSString stringWithFormat:@"MenuSelection.%s", kScreenNames[s]];
		const NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:key];
		if (saved > 0 && size_t(saved) < _entries.size()) _sel = int(saved);
		[self scrollToSelection];
		_dropOpen = getenv("RON_MENU_DROP") && s != kTutorials;  // snapshot check of the open drop-down
	}
	if (_interactive) [NSUserDefaults.standardUserDefaults setObject:@(kScreenNames[s]) forKey:launcher::kDefScreen];
}

- (void)openQuitPopup {
	_popup = Popup{};
	_popup.open = true, _popup.kind = 0;
	_popup.text = "Are you sure you want to quit Rise of Nations?";
	_popup.buttons = {"Yes", "No"};
}

- (void)setBusy:(NSString*)text {
	if (!text) {
		if (_popup.kind == 2) _popup = Popup{};
		return;
	}
	_popup = Popup{};
	_popup.open = true, _popup.kind = 2, _popup.text = text.UTF8String;
}

- (void)showError:(NSString*)text {
	_popup = Popup{};
	_popup.open = true, _popup.kind = 1, _popup.text = text.UTF8String, _popup.buttons = {"OK"};
}

- (std::string)soundFile:(const std::string&)key {
	for (const auto& [k, tags] : _soundGlobals) {
		if (k != key || tags.empty()) continue;
		for (const auto& [t, f] : _soundFiles) {
			if (t == tags.front()) return _files->resolve(f);
		}
	}
	return {};
}

- (void)click {
	if (_audio) {
		const std::string f = [self soundFile:"TOP_MENU_BUTTON"];
		if (!f.empty()) _audio->play_effect(f);
	}
}

- (void)startInteractive {
	_interactive = YES;
	_animT = 0;
	_lastFrame = 0;
	if (_audio) return;
	_audio = std::make_unique<ron::audio::Audio>();
	// The front end's music: Data/sound.xml TRACKS/INTROS, shuffled by the JukeBox like any mood.
	try {
		std::vector<std::string> intros;
		const ron::XmlElement doc = ron::parse_xml(_files->read_text("Data/sound.xml"));
		ron::for_each_element(doc, "INTROS", [&](const ron::XmlElement& e) {
			if (!intros.empty()) return;
			for (const ron::XmlElement& s : e.children) {
				const std::string f = _files->resolve(ron::normalize_game_path(s.get("file")));
				if (!f.empty()) intros.push_back(f);
			}
		});
		if (!intros.empty() && !getenv("RON_NO_MUSIC")) {
			_audio->set_music({{"economic", intros}}, "", "");
			_audio->update(_timeMs);
			_audio->music_start();
		}
	} catch (const std::exception& e) {
		std::fprintf(stderr, "menu music unavailable: %s\n", e.what());
	}
}

- (void)stopAudio {
	_audio.reset();
}

- (int)visibleRows {
	return std::max(1, [self layout].list.h() / kRowH);
}

- (void)scrollToSelection {
	const int rows = [self visibleRows];
	if (_sel < _top0) _top0 = _sel;
	if (_sel >= _top0 + rows) _top0 = _sel - rows + 1;
	_top0 = std::clamp(_top0, 0, std::max(0, int(_entries.size()) - rows));
}

// ---------------------------------------------------------------- layout (canvas pixels)

- (Layout)layout {
	Layout L;
	if (_screen == kMain) {
		// TopMenuSelection's window at the design's spot: frame (44, 112), the ribbon over its top edge.
		const int wx = 44, wy = 38;
		L.title = _titleRect.offset(wx, wy);
		L.title_text = _titleText.offset(wx, wy);
		int bottom = 0;
		for (int i = 0; i < 5; i++) {
			const IfaceRect r = _btnRect.offset(wx, wy + i * _btnInc);
			L.buttons.push_back(r);
			bottom = r.b;
		}
		L.frame = {wx + _btnRect.l - 41, wx + _btnRect.r + 41, L.title.t + _titleRect.h() - _titleRect.t + _titleRect.t, bottom + 41};
		L.frame.t = wy + _titleRect.h();  // client top + title height (TopMenuSelection::on_redraw)
		L.info = {44, 580, 452, 532};
		L.folder_y = 640;
		L.label_x = 44;
		L.change = {980 - 110, 980, 638, 666};
		L.edit = {0, L.change.l - 14, 640, 664};  // left edge set once the label is measured
	} else {
		const int tw = _titleRect.w(), th = _titleRect.h();
		L.title = {(kW - tw) / 2, (kW - tw) / 2 + tw, 22, 22 + th};
		L.title_text = {L.title.l, L.title.r, 22, 22 + _titleText.h()};
		L.note_y = 104;
		L.list_frame = {95, 929, 140, 630};
		L.list = {137, 863, 182, 588};
		L.scroll = {863, 887, 182, 588};
		L.up = {867, 883, 184, 200};
		L.down = {867, 883, 570, 586};
		L.track = {867, 883, 202, 568};
		const int n = int(_entries.size()), rows = std::max(1, L.list.h() / kRowH);
		L.rows = rows;
		if (n > rows) {
			const int th2 = std::max(24, L.track.h() * rows / n);
			const int maxTop = n - rows;
			const int y = L.track.t + (L.track.h() - th2) * _top0 / std::max(1, maxTop);
			L.thumb = {L.track.l, L.track.r, y, y + th2};
		}
		L.drop = {0, 0, 652, 673};  // placed after the label
		L.play = {912 - 173, 912, 646, 678};
		L.back = {L.play.l - 12 - 173, L.play.l - 12, 646, 678};
	}
	return L;
}

// ---------------------------------------------------------------- drawing helpers

- (void)menuButton:(const IfaceRect&)r label:(const char*)label hot:(bool)hot enabled:(bool)enabled {
	const IfaceRect R = r.offset(_ox, _oy);
	IfacePiece p[3] = {_btn[0], _btn[1], _btn[2]};
	for (IfacePiece& q : p) {
		if (!enabled) q.top += q.height + 1;
		else if (hot) q.top -= q.height + 1;
	}
	if (p[0].valid() && p[1].valid() && p[2].valid()) {
		_ui.add(p[0], float(R.l), float(R.t));
		_ui.add(p[2], float(R.r - p[2].width), float(R.t));
		_ui.tile(p[1], {R.l + p[0].width, R.r - p[2].width, R.t, R.t + p[1].height});
	}
	_ui.next_layer();
	const int f = _ui.font(18, -1);
	const IfaceRect tr = enabled ? R.offset(2, 2) : R;
	_ui.text_centered(f, label, tr, enabled ? kWhite : rgb(150, 150, 150), kButtonShadow);
}

- (void)popupButton:(const IfaceRect&)r label:(const std::string&)label state:(int)state font:(int)f {
	const IfaceRect R = r.offset(_ox, _oy);
	const IfacePiece* p = _popBtn[std::clamp(state, 0, 2)];
	if (p[0].valid() && p[1].valid() && p[2].valid()) _ui.expander(p[0], p[1], p[2], R);
	else _ui.fill(float(R.l), float(R.t), float(R.w()), float(R.h()), argb(255, 70, 70, 70));
	_ui.next_layer();
	_ui.text_centered(f, label, R, kWhite, kBlack);
}

- (void)thinBox:(const IfaceRect&)r fill:(uint32_t)fill {
	const IfaceRect R = r.offset(_ox, _oy);
	_ui.fill(float(R.l), float(R.t), float(R.w()), float(R.h()), fill, UiType::ColorBlend);
	_ui.next_layer();
	_ui.border(_thin, R);
}

- (void)banner:(const Layout&)L text:(const char*)text {
	_ui.next_window();
	if (_ribbon[0].valid()) _ui.expander(_ribbon[0], _ribbon[1], _ribbon[2], L.title.offset(_ox, _oy));
	_ui.next_layer();
	_ui.text_centered(_ui.font(22, -1), text, L.title_text.offset(_ox, _oy), kWhite, kBlack);
}

- (int)textAt:(int)f text:(const std::string&)s x:(float)x y:(float)y color:(uint32_t)c {
	_ui.text(f, s, x + float(_ox), y + float(_oy), c, kBlack);
	return _ui.text_width(f, s);
}

// ---------------------------------------------------------------- the backdrop

// The rect a 16:9 picture covers the window with (the original stretches it over the screen; the port keeps the
// picture's aspect and crops).
- (IfaceRect)coverFor:(int)w height:(int)h {
	const float a = float(w) / float(h);
	int cw = _uiW, ch = _uiH;
	if (float(_uiW) / float(_uiH) > a) ch = int(std::ceil(float(_uiW) / a));
	else cw = int(std::ceil(float(_uiH) * a));
	const int x = (_uiW - cw) / 2, y = (_uiH - ch) / 2;
	return {x, x + cw, y, y + ch};
}

- (void)drawBackdrop {
	_ui.next_window();
	if (_screen != kMain || _anims.empty()) {
		// The setup screens' antique map (TEX_TOPMENU_0, iface_wrapper1.tga), TopMenu's static_bg_tex.
		if (_staticBg.valid()) {
			const IfaceRect c = [self coverFor:_staticBg.width height:_staticBg.height];
			_ui.add(_staticBg, float(c.l), float(c.t), float(c.w()), float(c.h()), kWhite, UiType::Normal);
		}
		return;
	}
	const Anim& a = _anims[size_t(_anim) % _anims.size()];
	const float t = float(_animT);
	float alpha = 255;
	const float left = a.duration - t;
	if (left > 0 && left <= 1) alpha = left * 255;
	else if (t <= 0.5f) alpha = 0;
	else if (t <= 1.5f) alpha = std::clamp((t - 0.5f) * 255.0f, 0.0f, 255.0f);
	const uint32_t col = argb(int(alpha), 255, 255, 255);
	const IfaceRect c = a.layers.empty() ? IfaceRect{} : [self coverFor:a.layers.front().piece.width height:a.layers.front().piece.height];
	for (const AnimLayer& l : a.layers) {
		const float dx = float(c.w()) * (l.move_x * t + l.off_x), dy = float(c.h()) * (l.move_y * t + l.off_y);
		_ui.add(l.piece, float(c.l) + dx, float(c.t) + dy, float(c.w()), float(c.h()), col, UiType::ColorAlphaMod);
	}
}

- (void)advanceAnimation:(double)dt {
	if (_anims.empty() || _screen != kMain) return;
	_animT += dt;
	const Anim& a = _anims[size_t(_anim) % _anims.size()];
	if (_animT > a.duration) {
		for (const AnimLayer& l : a.layers) _ui.release(l.piece.texture);  // ~3.7 MB each; the next set loads on first use
		_animT = 0;
		_anim = (_anim + 1) % int(_anims.size());
	}
}

// The logo rect (canvas): the design's spot at the right of the menu.
- (IfaceRect)logoRect {
	return {505, 505 + 512, 35, 35 + 512};
}

- (void)encodeLogo:(id<MTLRenderCommandEncoder>)enc {
	if (_menuLogo) {
		// The design's spot (470 x 470 at right 28, top 56, drop-shadow(0 6px 14px rgba(0,0,0,.6))), 440 px on the same
		// vertical centre so that it clears the original's wider (536 px) bronze frame.
		const int size = 440, top = 56 + (470 - size) / 2;
		const IfaceRect r = IfaceRect{kW - 28 - size, kW - 28, top, top + size}.offset(_ox, _oy);
		const float blurLevel = std::log2(std::max(1.0f, 14.0f * float(_menuLogo.width) / float(size)));
		for (int pass = 0; pass < 2; pass++) {
			const float dy = pass == 0 ? 6 : 0;
			struct {
				float rect[4], view[4], light[4];
			} q = {{float(r.l), float(r.t) + dy, float(r.w()), float(r.h())}, {float(_uiW), float(_uiH), 0, 0}, {float(pass), blurLevel, 0, 0}};
			[enc setRenderPipelineState:_imagePipe];
			[enc setVertexBytes:&q length:sizeof q atIndex:0];
			[enc setFragmentBytes:&q length:sizeof q atIndex:0];
			[enc setFragmentTexture:_menuLogo atIndex:0];
			[enc setFragmentSamplerState:_logoSampler atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}
		return;
	}
	const IfaceRect r = [self logoRect].offset(_ox, _oy);
	if (!_logoPipe) return;
	// TopMenu::draw_logo: the light leans toward the mouse: dir = normalize(k * unit(centre - mouse), -1); the shader's
	// L (toward the light) is its negation, in UI axes (x right, y down, z toward the viewer).
	const float cx = float(r.l + r.w() / 2), cy = float(r.t + r.h() / 2);
	float mx = float(_mouse.x + _ox) - cx, my = float(_mouse.y + _oy) - cy;
	const float len = std::sqrt(mx * mx + my * my);
	if (len > 0.001f) mx /= len, my /= len;
	else mx = 0, my = -1;
	const float k = std::sqrt(2.0f) * 512.0f / float(kW);
	struct {
		float rect[4], view[4], light[4];
	} q = {{float(r.l), float(r.t), float(r.w()), float(r.h())}, {float(_uiW), float(_uiH), 0, 0}, {mx * k, my * k, 1, -1}};
	[enc setRenderPipelineState:_logoPipe];
	[enc setVertexBytes:&q length:sizeof q atIndex:0];
	[enc setFragmentBytes:&q length:sizeof q atIndex:0];
	[enc setFragmentTexture:_logoTex atIndex:0];
	[enc setFragmentTexture:_logoNormal atIndex:1];
	[enc setFragmentSamplerState:_logoSampler atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// ---------------------------------------------------------------- screens

- (void)drawMain:(const Layout&)L {
	// The bronze frame around the buttons, then the ribbon over its top edge (TopMenuSelection::on_redraw).
	_ui.next_window();
	_ui.border(_border, L.frame.offset(_ox, _oy));
	[self banner:L text:"Main Menu"];
	_ui.next_layer();
	for (int i = 0; i < 5; i++) {
		const bool hot = _hover == kMainBtn + i || _pressed == kMainBtn + i || (_hover == kNone && _focus == i && !_popup.open);
		[self menuButton:L.buttons[size_t(i)] label:kMainItems[i].label hot:hot && kMainItems[i].enabled enabled:kMainItems[i].enabled];
		_ui.next_layer();
	}
	// Help box (TopMenu::on_window_redraw): the hovered button's help, font 16, in the MOTD style box.
	_ui.next_window();
	[self thinBox:L.info fill:argb(100, 0, 0, 0)];
	_ui.next_layer();
	const int hf = _ui.font(16, -1);
	const ron::FontMetrics* hm = _ui.font_metrics(hf);
	int y = L.info.t + 10;
	for (const std::string& line : wrap_text(_ui, hf, _help, L.info.w() - 20)) {
		[self textAt:hf text:line x:float(L.info.l + 10) y:float(y) color:kWhite];
		y += hm ? hm->line_height : 20;
	}
	// Game folder row.
	_ui.next_window();
	const int f14 = _ui.font(14, -1);
	const ron::FontMetrics* m14 = _ui.font_metrics(f14);
	const int fh = m14 ? m14->font_height : 16;
	const int lw = [self textAt:f14 text:"Game Folder:" x:float(L.label_x) y:float(L.edit.t + (L.edit.h() - fh) / 2) color:kLabel];
	IfaceRect edit = L.edit;
	edit.l = L.label_x + lw + 14;
	[self thinBox:edit fill:argb(170, 0, 0, 0)];
	_ui.next_layer();
	std::string path = _dir.UTF8String;
	const int room = edit.w() - 16;
	if (_ui.text_width(f14, path) > room) {
		while (path.size() > 4 && _ui.text_width(f14, "..." + path) > room) path.erase(0, 1);
		path = "..." + path;
	}
	[self textAt:f14 text:path x:float(edit.l + 8) y:float(edit.t + (edit.h() - fh) / 2) color:kWhite];
	[self popupButton:L.change label:"Change…" state:(_pressed == kChange ? 2 : _hover == kChange ? 1 : 0) font:f14];
	[self textAt:f14 text:"Your game files are ready." x:float(L.label_x) y:float(L.edit.b + 10) color:kSecondary];
}

- (void)drawList:(const Layout&)L {
	[self banner:L text:kListTitles[_screen]];
	_ui.next_window();
	const int f14 = _ui.font(14, -1), f12 = _ui.font(12, -1);
	const ron::FontMetrics* m14 = _ui.font_metrics(f14);
	const int lh = m14 ? m14->line_height : 16;
	int y = L.note_y;
	for (const std::string& line : wrap_text(_ui, f14, kListNotes[_screen], 800)) {
		[self textAt:f14 text:line x:float((kW - _ui.text_width(f14, line)) / 2) y:float(y) color:kSecondary];
		y += lh;
	}
	// The list in the bronze frame on a dark wash.
	_ui.next_window();
	const IfaceRect inner{L.list_frame.l + 30, L.list_frame.r - 30, L.list_frame.t + 30, L.list_frame.b - 30};
	_ui.fill(float(inner.l + _ox), float(inner.t + _oy), float(inner.w()), float(inner.h()), argb(150, 13, 11, 40), UiType::ColorBlend);
	_ui.next_layer();
	_ui.border(_border, L.list_frame.offset(_ox, _oy));
	_ui.next_layer();
	const int n = int(_entries.size());
	if (n == 0) {
		const char* none = "None of these maps were found in your game folder.";
		[self textAt:f14 text:none x:float(L.list.l + (L.list.w() - _ui.text_width(f14, none)) / 2) y:float(L.list.t + 20) color:kSecondary];
	}
	const int rowW = n > L.rows ? L.list.w() - 4 : L.scroll.r - L.list.l;
	for (int r = 0; r < L.rows && _top0 + r < n; r++) {
		const int i = _top0 + r;
		const IfaceRect row{L.list.l, L.list.l + rowW, L.list.t + r * kRowH, L.list.t + (r + 1) * kRowH};
		const IfaceRect R = row.offset(_ox, _oy);
		if (i == _sel || _hover == kRow + i) {
			IfacePiece p[3] = {_large[0], _large[1], _large[2]};
			if (i != _sel)
				for (IfacePiece& q : p) q.top += q.height + 1;  // the darker row below for the hovered entry
			if (p[0].valid()) _ui.expander(p[0], p[1], p[2], {R.l, R.r, R.t + 1, R.b - 1});
		}
		_ui.next_layer();
		const launcher::Entry& e = _entries[size_t(i)];
		_ui.text(f14, e.title, float(R.l + 14), float(R.t + 5), kWhite, kBlack);
		_ui.text(f12, e.detail, float(R.l + 14), float(R.t + 23), i == _sel ? rgb(225, 225, 235) : kSecondary, kBlack);
		_ui.next_layer();
	}
	if (n > L.rows) {  // SCROLLCLASS: vertical back, slider, arrow buttons
		const IfaceRect s = L.scroll.offset(_ox, _oy), u = L.up.offset(_ox, _oy), d = L.down.offset(_ox, _oy);
		if (_scrollBack[0].valid()) _ui.vexpander(_scrollBack[0], _scrollBack[1], _scrollBack[2], s);
		_ui.next_layer();
		if (_scrollSlider[0].valid()) _ui.vexpander(_scrollSlider[0], _scrollSlider[1], _scrollSlider[2], L.thumb.offset(_ox + 0, _oy));
		_ui.add(_scrollUp, float(u.l), float(u.t));
		_ui.add(_scrollDown, float(d.l), float(d.t));
		_ui.next_layer();
	}
	// Bottom row: AI difficulty, Back, Play.
	_ui.next_window();
	if (_screen != kTutorials) {
		const ron::FontMetrics* fm = _ui.font_metrics(f14);
		const int fh = fm ? fm->font_height : 16;
		const int lw = [self textAt:f14 text:"AI Difficulty:" x:112 y:float(L.drop.t + (L.drop.h() - fh) / 2) color:kLabel];
		IfaceRect drop = L.drop;
		drop.l = 112 + lw + 12, drop.r = drop.l + 170;
		const IfaceRect D = drop.offset(_ox, _oy);
		// The GameSpy dialog's combo box: white field (left / mid / right) and the arrow button at the right.
		if (_combo[0].valid()) {
			const IfaceRect field{D.l, D.r - _combo[3].width + 2, D.t, D.b};
			_ui.expander(_combo[0], _combo[1], _combo[2], field);
			_ui.add(_combo[3], float(D.r - _combo[3].width), float(D.t));
		} else {
			[self thinBox:drop fill:rgb(240, 240, 240)];
		}
		_ui.next_layer();
		const int fo = _ui.font(12, 1);
		const ron::FontMetrics* om = _ui.font_metrics(fo);
		const int oh = om ? om->font_height : 14;
		_ui.text(fo, kDifficulty[_difficulty], float(D.l + 7), float(D.t + (D.h() - oh) / 2), kBlack);
		if (_dropOpen) {  // the option list opens upward (the box sits at the bottom of the screen)
			_ui.next_window();
			const int ih = 20, lh2 = 6 * ih + 6;
			const IfaceRect list{drop.l, drop.r - _combo[3].width, drop.t - lh2 - 2, drop.t - 2};
			[self thinBox:list fill:rgb(244, 244, 240)];
			_ui.next_layer();
			for (int k = 0; k < 6; k++) {
				const IfaceRect it{list.l + 3, list.r - 3, list.t + 3 + k * ih, list.t + 3 + (k + 1) * ih};
				const IfaceRect I = it.offset(_ox, _oy);
				const bool hot = _hover == kDropItem + k || (_hover < kDropItem && k == _difficulty);
				if (hot) _ui.fill(float(I.l), float(I.t), float(I.w()), float(I.h()), rgb(53, 47, 132), UiType::ColorBlend);
				_ui.next_layer();
				_ui.text(fo, kDifficulty[k], float(I.l + 5), float(I.t + (ih - oh) / 2), hot ? kWhite : kBlack);
			}
		}
	}
	_ui.next_window();
	const int fb = _ui.font(14, -1);
	[self popupButton:L.back label:"Back" state:(_pressed == kBack ? 2 : _hover == kBack ? 1 : 0) font:fb];
	[self popupButton:L.play label:"Play" state:(_pressed == kPlay ? 2 : _hover == kPlay ? 1 : 0) font:fb];
}

- (void)drawPopup {
	if (!_popup.open) return;
	_ui.next_window();
	_ui.fill(0, 0, float(_uiW), float(_uiH), argb(115, 0, 0, 0), UiType::ColorBlend);
	_ui.next_layer();
	const int f = _ui.font(14, -1);
	const ron::FontMetrics* m = _ui.font_metrics(f);
	const int lh = m ? m->line_height : 16;
	const std::vector<std::string> lines = wrap_text(_ui, f, _popup.text, 360);
	int tw = 0;
	for (const auto& l : lines) tw = std::max(tw, _ui.text_width(f, l));
	const int bw = 173, bh = 32, gap = 12, nb = int(_popup.buttons.size());
	const int w = std::max({tw, nb * bw + std::max(0, nb - 1) * gap, 240}) + 48;
	const int h = int(lines.size()) * lh + (nb ? bh + 24 : 0) + 48;
	const int x = (kW - w) / 2, y = (kH - h) / 2;
	[self thinBox:{x, x + w, y, y + h} fill:_popBg];
	_ui.next_layer();
	int ty = y + 24;
	for (const auto& l : lines) {
		[self textAt:f text:l x:float(x + (w - _ui.text_width(f, l)) / 2) y:float(ty) color:kWhite];
		ty += lh;
	}
	_popup.rects.clear();
	int bx = x + (w - (nb * bw + std::max(0, nb - 1) * gap)) / 2;
	for (int i = 0; i < nb; i++) {
		const IfaceRect r{bx, bx + bw, y + h - 24 - bh, y + h - 24};
		_popup.rects.push_back(r);
		[self popupButton:r label:_popup.buttons[size_t(i)] state:(_pressed == kPopupBtn + i ? 2 : _hover == kPopupBtn + i ? 1 : 0) font:f];
		bx += bw + gap;
	}
}

// ---------------------------------------------------------------- frame

- (void)updateMapping:(CGSize)points {
	const float pw = float(std::max(1.0, points.width)), ph = float(std::max(1.0, points.height));
	_fit = std::min(pw / kW, ph / kH);
	_uiW = int(std::ceil(pw / _fit)), _uiH = int(std::ceil(ph / _fit));
	_ox = (_uiW - kW) / 2, _oy = (_uiH - kH) / 2;
}

- (void)renderInto:(id<MTLTexture>)output commandBuffer:(id<MTLCommandBuffer>)cb points:(CGSize)points {
	[self updateMapping:points];
	const float scale = float(output.width) / float(_uiW);
	MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = output;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
	_ui.set_smooth(std::fabs(scale - std::round(scale)) > 0.01f);
	// 1. backdrop, 2. the logo (main menu), 3. the windows.
	_ui.begin(_uiW, _uiH, scale, kW);
	[self drawBackdrop];
	if (_screen == kMain && !_menuLogo && !_logoPipe && _flatLogo.valid()) {
		const IfaceRect r = [self logoRect].offset(_ox, _oy);
		_ui.next_window();
		_ui.add(_flatLogo, float(r.l), float(r.t + 512 / 2 - _flatLogo.height / 2));
	}
	_ui.encode(enc);
	if (_screen == kMain) [self encodeLogo:enc];
	_ui.begin(_uiW, _uiH, scale, kW);
	const Layout L = [self layout];
	if (_screen == kMain) [self drawMain:L];
	else [self drawList:L];
	[self drawPopup];
	_ui.encode(enc);
	[enc endEncoding];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView*)view {
	const double now = CACurrentMediaTime();
	const double dt = _lastFrame > 0 ? std::min(0.1, now - _lastFrame) : 0;
	_lastFrame = now;
	_timeMs += dt * 1000.0;
	[self advanceAnimation:dt];
	if (_audio) _audio->update(_timeMs);
	id<CAMetalDrawable> drawable = view.currentDrawable;
	if (!drawable) return;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	[self renderInto:drawable.texture commandBuffer:cb points:view.bounds.size];
	[cb presentDrawable:drawable];
	[cb commit];
}

- (BOOL)snapshotTo:(NSString*)path width:(int)w height:(int)h scale:(float)scale {
	id<MTLTexture> out = rm::make_readback_target(_device, w, h);
	if (scale <= 0) scale = 1;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	[self renderInto:out commandBuffer:cb points:CGSizeMake(w / scale, h / scale)];
	[cb commit];
	[cb waitUntilCompleted];
	if (!rm::write_png(out, path.UTF8String)) {
		std::fprintf(stderr, "could not write %s\n", path.UTF8String);
		return NO;
	}
	std::printf("wrote %s (%dx%d, menu %s)\n", path.UTF8String, w, h, kScreenNames[_screen]);
	return YES;
}

// ---------------------------------------------------------------- input

- (CGPoint)canvas:(CGPoint)p {
	return CGPointMake(p.x / _fit - _ox, p.y / _fit - _oy);
}

- (int)hit:(CGPoint)c {
	const int x = int(std::floor(c.x)), y = int(std::floor(c.y));
	const Layout L = [self layout];
	if (_popup.open) {
		for (size_t i = 0; i < _popup.rects.size(); i++) {
			if (_popup.rects[i].contains(x, y)) return kPopupBtn + int(i);
		}
		return kNone;
	}
	if (_screen == kMain) {
		for (int i = 0; i < 5; i++) {
			if (L.buttons[size_t(i)].contains(x, y) && kMainItems[i].enabled) return kMainBtn + i;
		}
		if (L.change.contains(x, y)) return kChange;
		return kNone;
	}
	if (L.back.contains(x, y)) return kBack;
	if (L.play.contains(x, y)) return kPlay;
	if (_screen != kTutorials) {
		const IfaceRect drop = [self dropRect];
		if (_dropOpen) {
			const int ih = 20, lh2 = 6 * ih + 6;
			const IfaceRect list{drop.l, drop.r - _combo[3].width, drop.t - lh2 - 2, drop.t - 2};
			for (int k = 0; k < 6; k++) {
				if (IfaceRect{list.l + 3, list.r - 3, list.t + 3 + k * ih, list.t + 3 + (k + 1) * ih}.contains(x, y)) return kDropItem + k;
			}
		}
		if (drop.contains(x, y)) return kDrop;
	}
	const int n = int(_entries.size());
	if (n > L.rows) {
		if (L.up.contains(x, y)) return kScrollUp;
		if (L.down.contains(x, y)) return kScrollDown;
		if (L.thumb.contains(x, y)) return kThumb;
		if (L.scroll.contains(x, y)) return kTrack;
	}
	if (L.list.contains(x, y)) {
		const int i = _top0 + (y - L.list.t) / kRowH;
		if (i >= 0 && i < n) return kRow + i;
	}
	return kNone;
}

- (IfaceRect)dropRect {
	const int f14 = _ui.font(14, -1);
	const int lw = _ui.text_width(f14, "AI Difficulty:");
	const Layout L = [self layout];
	IfaceRect d = L.drop;
	d.l = 112 + lw + 12, d.r = d.l + 170;
	return d;
}

- (void)setHover:(int)h {
	_hover = h;
	if (_screen == kMain && h >= kMainBtn && h < kMainBtn + 5) {
		_help = kMainItems[h - kMainBtn].help;
		_focus = h - kMainBtn;
	}
}

- (void)mouseMoved:(CGPoint)p {
	_mouse = [self canvas:p];
	_mouseKnown = YES;
	int h = [self hit:_mouse];
	// The help box also explains the disabled Multiplayer button.
	if (_screen == kMain && !_popup.open && h == kNone) {
		const Layout L = [self layout];
		if (L.buttons[3].contains(int(_mouse.x), int(_mouse.y))) _help = kMainItems[3].help;
	}
	[self setHover:h];
}

- (void)mouseDown:(CGPoint)p clicks:(NSInteger)clicks {
	_mouse = [self canvas:p];
	const int h = [self hit:_mouse];
	if (_dropOpen && !(h >= kDropItem && h < kDropItem + 6) && h != kDrop) {
		_dropOpen = NO;
		return;
	}
	_pressed = h;
	if (h >= kRow) {
		_sel = h - kRow;
		[self remember];
		const double now = CACurrentMediaTime() * 1000.0;
		if (clicks >= 2 && _lastClickRow == _sel) [self play];
		_lastClickRow = _sel, _lastClickMs = now;
		_pressed = kNone;
	} else if (h == kThumb) {
		_dragThumb = YES;
		_dragOffset = int(_mouse.y) - [self layout].thumb.t;
	} else if (h == kScrollUp || h == kScrollDown) {
		[self scrollBy:h == kScrollUp ? -1 : 1];
	} else if (h == kTrack) {
		const Layout L = [self layout];
		[self scrollBy:int(_mouse.y) < L.thumb.t ? -L.rows : L.rows];
	}
}

- (void)mouseDragged:(CGPoint)p {
	_mouse = [self canvas:p];
	if (_dragThumb) {
		const Layout L = [self layout];
		const int n = int(_entries.size()), maxTop = std::max(0, n - L.rows);
		const int span = std::max(1, L.track.h() - L.thumb.h());
		_top0 = std::clamp(int(std::lround(double(int(_mouse.y) - _dragOffset - L.track.t) * maxTop / span)), 0, maxTop);
		return;
	}
	_hover = [self hit:_mouse] == _pressed ? _pressed : kNone;
}

- (void)mouseUp:(CGPoint)p {
	_mouse = [self canvas:p];
	_dragThumb = NO;
	const int h = [self hit:_mouse];
	const int pressed = _pressed;
	_pressed = kNone;
	if (h != pressed || h == kNone) return;
	[self activate:h];
	[self setHover:[self hit:_mouse]];
}

- (void)scrollWheel:(CGFloat)dy at:(CGPoint)p {
	if (_screen == kMain || _popup.open) return;
	static CGFloat acc = 0;
	acc += dy;
	while (acc >= 1) [self scrollBy:-1], acc -= 1;
	while (acc <= -1) [self scrollBy:1], acc += 1;
}

- (void)scrollBy:(int)rows {
	const Layout L = [self layout];
	_top0 = std::clamp(_top0 + rows, 0, std::max(0, int(_entries.size()) - L.rows));
}

- (void)remember {
	NSString* key = [NSString stringWithFormat:@"MenuSelection.%s", kScreenNames[_screen]];
	[NSUserDefaults.standardUserDefaults setInteger:_sel forKey:key];
}

- (void)play {
	if (_sel < 0 || size_t(_sel) >= _entries.size()) return;
	[self click];
	[self remember];
	const int diff = _screen == kTutorials ? -1 : _difficulty;
	if (_screen == kSkirmish)
		[self.host frontEndConfigureSkirmish:@(_entries[size_t(_sel)].path.c_str()) difficulty:diff];
	else [self.host frontEndPlay:@(_entries[size_t(_sel)].path.c_str()) difficulty:diff];
}

- (void)activate:(int)h {
	if (_popup.open) {
		if (h < kPopupBtn) return;
		const int b = h - kPopupBtn;
		const int kind = _popup.kind;
		_popup = Popup{};
		[self click];
		if (kind == 0 && b == 0) [self.host frontEndQuit];
		return;
	}
	if (h >= kMainBtn && h < kMainBtn + 5) {
		[self click];
		switch (h - kMainBtn) {
			case 0: [self showScreen:@"tutorials"]; break;
			case 1: [self showScreen:@"skirmish"]; break;
			case 2: [self showScreen:@"scenarios"]; break;
			case 4: [self openQuitPopup]; break;
			default: break;
		}
		return;
	}
	if (h == kChange) {
		[self click];
		[self.host frontEndChangeFolder];
	} else if (h == kBack) {
		[self click];
		[self showScreen:@"main"];
		_focus = std::max(0, int(_screen));
	} else if (h == kPlay) {
		[self play];
	} else if (h == kDrop) {
		_dropOpen = !_dropOpen;
	} else if (h >= kDropItem && h < kDropItem + 6) {
		_difficulty = h - kDropItem;
		_dropOpen = NO;
		[NSUserDefaults.standardUserDefaults setInteger:_difficulty forKey:launcher::kDefDifficulty];
	}
}

- (void)keyDown:(NSEvent*)e {
	NSString* chars = e.charactersIgnoringModifiers;
	const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
	const bool ret = c == '\r' || c == 3, esc = e.keyCode == 53;
	_hover = kNone;
	if (_popup.open) {
		if (_popup.kind == 2) return;  // busy
		if (esc) {
			_popup = Popup{};  // No / OK
		} else if (ret) {
			[self activate:kPopupBtn + (_popup.kind == 0 ? 0 : 0)];
		}
		return;
	}
	if (_dropOpen) {
		if (c == NSUpArrowFunctionKey) _difficulty = std::max(0, _difficulty - 1);
		else if (c == NSDownArrowFunctionKey) _difficulty = std::min(5, _difficulty + 1);
		else if (ret || esc) {
			_dropOpen = NO;
			[NSUserDefaults.standardUserDefaults setInteger:_difficulty forKey:launcher::kDefDifficulty];
		}
		return;
	}
	if (_screen == kMain) {
		auto step = [&](int d) {
			for (int k = 0; k < 5; k++) {
				_focus = (_focus + d + 5) % 5;
				if (kMainItems[_focus].enabled) break;
			}
			_help = kMainItems[_focus].help;
		};
		if (c == NSUpArrowFunctionKey) step(-1);
		else if (c == NSDownArrowFunctionKey) step(1);
		else if (ret) [self activate:kMainBtn + _focus];
		else if (esc) [self openQuitPopup];  // TopMenuSelection::on_key_down: Esc at the top menu asks to quit
		return;
	}
	const int n = int(_entries.size()), rows = [self layout].rows;
	if (c == NSUpArrowFunctionKey) _sel = std::max(0, _sel - 1);
	else if (c == NSDownArrowFunctionKey) _sel = std::min(n - 1, _sel + 1);
	else if (c == NSPageUpFunctionKey) _sel = std::max(0, _sel - rows);
	else if (c == NSPageDownFunctionKey) _sel = std::min(n - 1, _sel + rows);
	else if (c == NSHomeFunctionKey) _sel = 0;
	else if (c == NSEndFunctionKey) _sel = n - 1;
	else if (c == NSLeftArrowFunctionKey && _screen != kTutorials) _difficulty = std::max(0, _difficulty - 1);
	else if (c == NSRightArrowFunctionKey && _screen != kTutorials) _difficulty = std::min(5, _difficulty + 1);
	else if (ret) [self play];
	else if (esc) {
		const Screen from = _screen;
		[self click];
		[self showScreen:@"main"];
		_focus = int(from) - 1;
		_help = kMainItems[_focus].help;
		return;
	}
	if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey)
		[NSUserDefaults.standardUserDefaults setInteger:_difficulty forKey:launcher::kDefDifficulty];
	_sel = std::max(0, _sel);
	[self scrollToSelection];
	[self remember];
}

- (NSCursor*)cursor {
	if (!_cursor) _cursor = ron_game_cursor(*_files, ron::kCursorMain);
	return _cursor;
}

@end
