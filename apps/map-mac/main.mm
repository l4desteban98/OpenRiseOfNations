// ronmap: render a Rise of Nations scenario on macOS (AppKit + Metal) with the game's camera, its units driven by the
// simulation (engine/sim).
//
// Usage: ronmap [game-dir] [--menu [SCREEN] [--snapshot out.png [--size WxH]]]
//        ronmap [game-dir] <scenario.scx> [--zoom LEVEL] [--at X,Y] [--no-bloom] [--build NAME@X,Y[@TEAM] ...]
//               [--unit NAME@X,Y[@ANGLE] ...] [--no-sim] [--seed S] [--difficulty 0..5]
//               [--move WHO:o1,o2,...@X,Y[@FRAME] ...] [--attack WHO:o1,...@TWHO:TO[@FRAME] ...] [--frames N]
//               [--farm-time SECONDS] [--snapshot out.png [--size WxH]] [--no-hud] [--ui-scale S]
//               [--play WHO] [--select WHO:o1,o2,...] [--place-click] [--queue WHO:O@TYPE[*N]] [--select-build WHO:o1,...] [--build-page N] [--place TYPE@X,Y]
//               [--select WHO:o1,...@FRAME] [--option N[:MENU[:TYPE]]@FRAME] [--cursor X,Y@FRAME] [--look X,Y@FRAME]
//               [--zoom-at LEVEL@FRAME] [--script-log]
//   LEVEL is the game's zoom level 0 (far) .. 6 (closest); the game starts at 5. X,Y is the look-at point in world
//   units (default: player 1's start camera, else the map centre). The scenario's buildings and units are placed
//   automatically; --build / --unit add more by graphic name (static). --snapshot renders offscreen to a PNG and exits.
//   --farm-time runs that many seconds of unattended wheat growth first (a loaded scenario starts with bare farms).
//   The scenario's units are simulated (one frame per 67 ms, the game's normal speed) unless --no-sim. --move issues a
//   GROUP + MOVE_TO for leader WHO's units at FRAME (default 0) and --frames steps the simulation N frames before the
//   window opens or the snapshot is taken (headless checks).
//
//   The HUD (docs/ui-port.md) is drawn over the map and in snapshots unless --no-hud; --select / --select-build pick
//   objects for the selection panel and the command card, --build-page opens a citizen's build menu page, --place previews
//   placing building TYPE (TypeIndex) at X,Y.
//
//   Scenario scripts (docs/ui-port.md "Script UI"): the HUD's state is reported to the scripts every frame (selection,
//   armed command, build page, cursor, interface rectangles, camera, keys, sound playback) and their presentation is
//   drawn (objectives, messages, pings, arrows, flags, highlights, camera moves, locks, popups) and played (scenario
//   sounds, music) in the window. Headless checks: --select WHO:o1,..@FRAME selects as a click would at FRAME (an empty
//   list clears); --option N[:MENU[:TYPE]]@FRAME clicks command-card option N (OptionIndex: 9 Move, 0 / 1 / 2 the build
//   menus, -1 cancels), MENU opens a build page, TYPE starts placing that building; --cursor X,Y@FRAME puts the mouse
//   over world point X,Y; --look / --zoom-at move the camera as the player would; --script-log prints the
//   presentation queue as it is consumed.
//
//   Without a scenario the window opens in the front end (docs/ui-port.md "Front end"): the Main Menu drawn with the
//   install's own menu art, its Tutorials / Skirmish / Scenarios lists, Play starting the chosen map in the same window.
//   --menu SCREEN (main, tutorials, skirmish, scenarios, quit-popup) opens that screen; with --snapshot it is rendered
//   headless. The game folder comes from the command line, the remembered folder, or the usual install locations; a
//   native folder picker asks only when none is found.
//
// Controls (docs/ui-spec.md 4): click select (Shift adds, Ctrl/Cmd toggles, double click = same type on screen), drag a
//           box (units before buildings, 128 max); right-click: move / attack / rally point; minimap: click or drag to
//           look, right-click to order; Ctrl+0..9 stores a control group (no selection: a camera bookmark), 0..9 recalls,
//           twice centres; edge scrolling (2 px), mouse wheel / pinch zoom toward the cursor, trackpad scroll pans;
//           arrows scroll   + - zoom level   P pause   F fog   B bloom   H HUD   Esc cancel / clear / game menu   F10 game menu
//           (Resume, Return to Main Menu, Quit); the game-over screen offers Return to Main Menu.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#include <simd/simd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "assets/battlefield.hpp"
#include "assets/bh3.hpp"
#include "assets/bha.hpp"
#include "assets/buildings.hpp"
#include "assets/catalog.hpp"
#include "assets/effects.hpp"
#include "assets/files.hpp"
#include "assets/graphics_txt.hpp"
#include "assets/rules.hpp"
#include "assets/xml.hpp"
#include "assets/pose.hpp"
#include "assets/scenario.hpp"
#include "assets/tga.hpp"
#include "assets/tileset.hpp"
#include "render/dressing.hpp"
#include "render/farms.hpp"
#include "render/fog_overlay.hpp"
#include "render/forest.hpp"
#include "render/rivers.hpp"
#include "render/lighting.hpp"
#include "render/renderstate.hpp"
#include "render/terrain_mesh.hpp"
#include "sim/anim_assets.hpp"
#include "sim/commands.hpp"
#include "sim/game.hpp"
#import "skirmish_setup.h"
#include <optional>
#include "sim/rules.hpp"
#include "sim/rules_xml.hpp"
#include "sim/script_host.hpp"
#include "sim/view.hpp"
#include "assets/cursors.hpp"
#include "assets/iface_layout.hpp"
#include "sim/production.hpp"
#include "hud.hpp"
#include "script_view.hpp"
#include "audio.hpp"
#include "sim/script_ui.hpp"
#include "renderer.hpp"
#include "ui.hpp"
#include "unit_draw.hpp"
#import "frontend.h"
#import "launcher.h"

namespace rm = ron::metal;

// Game camera (docs/terrain-spec.md B7): orthographic, yaw 45 degrees, 30 degrees above the horizon.
// Basis from the disassembly; viewed from above, world +x runs right-down and +y left-down on screen.
static const simd_float3 kRight = {0.70710678f, -0.70710678f, 0.0f};
static const simd_float3 kUp = {-0.35355339f, -0.35355339f, 0.8660254f};
static const simd_float3 kBack = {0.61237244f, 0.61237244f, 0.5f};  // from the look-at point toward the eye
// World units per pixel at each zoom level, for screens at least 1280 pixels wide: 3 / ratio[level].
static const float kZoomRatio[7] = {0.08f, 0.1f, 0.25f, 1.0f / 3.0f, 0.5f, 2.0f / 3.0f, 1.0f};

static float units_per_pixel(int level, float screen_w) {
	return 3.0f * std::max(screen_w, 1280.0f) / screen_w / kZoomRatio[std::clamp(level, 0, 6)];
}

// View (rows: right, up, back) and orthographic projection to Metal clip space (depth 0..1).
static void camera_matrices(simd_float3 look_at, float upp, float w, float h, simd_float4x4& view, simd_float4x4& proj) {
	const float dist = 60000.0f;
	const simd_float3 eye = look_at + kBack * dist;
	view = simd_matrix(simd_make_float4(kRight.x, kUp.x, kBack.x, 0), simd_make_float4(kRight.y, kUp.y, kBack.y, 0),
	                   simd_make_float4(kRight.z, kUp.z, kBack.z, 0),
	                   simd_make_float4(-simd_dot(kRight, eye), -simd_dot(kUp, eye), -simd_dot(kBack, eye), 1));
	const float zn = 1000.0f, zf = 2.0f * dist;
	proj = simd_matrix(simd_make_float4(2.0f / (w * upp), 0, 0, 0), simd_make_float4(0, 2.0f / (h * upp), 0, 0),
	                   simd_make_float4(0, 0, -1.0f / (zf - zn), 0), simd_make_float4(0, 0, -zn / (zf - zn), 1));
}

// Terrain render states (TerrainOut's own, not in the named table): "Base Terrain" is TEXTURE x DIFFUSE (the baked
// vertex light) with vertex alpha, alpha-blended, depth test and write, and lit again in the shader; water is the
// vertex colour, lit, blended over everything, no depth write. docs/lighting-spec.md section 7.
static ron::RenderState land_state() {
	ron::RenderState rs;
	rs.name = "Terrain Land";
	rs.enables = ron::rs_enable::kDepthTest | ron::rs_enable::kDepthWrite | ron::rs_enable::kAlphaBlend | ron::rs_enable::kLighting;
	rs.src_blend = ron::BlendMode::SrcAlpha;
	rs.dst_blend = ron::BlendMode::InvSrcAlpha;
	rs.cull = ron::CullMode::CCW;
	rs.stage[0] = {ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Diffuse,
	               ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Diffuse, 0,
	               ron::TexAddress::Wrap, ron::TexAddress::Wrap};
	return rs;
}

// Trees: the game's "Tree Blend" (fake-lit). Its diffuse is the tree's vertex colour and tfactor is set per draw in
// flush_trees (not decoded yet): a neutral 0.5 grey diffuse makes ADDSIGNED pass the texture through.
static ron::RenderState tree_state() {
	ron::RenderState rs = *ron::find_render_state("Tree Blend");
	rs.cull = ron::CullMode::None;
	return rs;
}

// Transitions (TerrainOut+0x442c): depth test LESSEQUAL without write, blended, lit. Colour = ground texture x diffuse,
// alpha = diffuse alpha x mask alpha (stage 1 samples the mask with UV1). docs/terrain-spec.md B2a T8.
static ron::RenderState transition_state() {
	ron::RenderState rs = land_state();
	rs.name = "Transitions";
	rs.enables = ron::rs_enable::kDepthTest | ron::rs_enable::kAlphaBlend | ron::rs_enable::kLighting;
	rs.stage[0].address_u = rs.stage[0].address_v = ron::TexAddress::Clamp;
	rs.stage[1] = {ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current, 1,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	return rs;
}

// Ocean overlays ("CoralSandy", then "CoralTrans" with the coral texture): no depth test, alpha from the mask only.
static ron::RenderState coral_state(bool coral) {
	ron::RenderState rs = transition_state();
	rs.name = coral ? "CoralTrans" : "CoralSandy";
	rs.enables = ron::rs_enable::kAlphaBlend | ron::rs_enable::kLighting | ron::rs_enable::kPointSampling;
	rs.stage[0].address_u = rs.stage[0].address_v = coral ? ron::TexAddress::Clamp : ron::TexAddress::Wrap;
	rs.stage[1].alpha_op = ron::TextureOp::SelectArg1;
	return rs;
}

// "OceanFloor": depth test without write, no blending, lit; rgb = tex(UV0) x tex(UV1) x 2 x diffuse (water-spec 2.5).
static ron::RenderState floor_state() {
	ron::RenderState rs = land_state();
	rs.name = "OceanFloor";
	rs.enables = ron::rs_enable::kDepthTest | ron::rs_enable::kLighting;
	rs.stage[0] = {ron::TextureOp::Modulate2x, ron::TextureArg::Texture, ron::TextureArg::Diffuse,
	               ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Diffuse, 0,
	               ron::TexAddress::Wrap, ron::TexAddress::Wrap};
	rs.stage[1] = {ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Current, 1,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	return rs;
}

// "Mountain Blend" (MountainsOut): rgb = tex0 x diffuse + tex1 - 0.5, a = tex0.a x tex1.a; depth test and write,
// alpha test > 0, lit. Stage 1 carries the range's RING/MAIN alpha with baked shading on UV1.
static ron::RenderState mountain_state() {
	ron::RenderState rs;
	rs.name = "Mountain Blend";
	rs.enables = 0x287;
	rs.src_blend = ron::BlendMode::SrcAlpha;
	rs.dst_blend = ron::BlendMode::InvSrcAlpha;
	rs.alpha_func = ron::CompareFunc::Greater;
	rs.cull = ron::CullMode::CCW;
	rs.stage[0] = {ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Diffuse,
	               ron::TextureOp::SelectArg1, ron::TextureArg::Texture, ron::TextureArg::Current, 0,
	               ron::TexAddress::Wrap, ron::TexAddress::Wrap};
	rs.stage[1] = {ron::TextureOp::AddSigned, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current, 1,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	return rs;
}

// "Weathering Underlay" (snowcaps): no depth test, blended, fake-lit; rgb = tex(UV0) x diffuse, a = tex(UV1).a.
static ron::RenderState snowcap_state() {
	ron::RenderState rs = mountain_state();
	rs.name = "Weathering Underlay";
	rs.enables = 0x20004;
	rs.stage[0] = {ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Diffuse,
	               ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Diffuse, 0,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	rs.stage[1] = {ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::SelectArg1, ron::TextureArg::Texture, ron::TextureArg::Current, 1,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	return rs;
}

// Fog-of-war overlay (docs/fog-spec.md 9.2): the FOGTEX ramp's colour and alpha (black, alpha by fog level), blended
// over everything drawn on the ground; depth tested so objects standing in front are not covered, no depth write.
static ron::RenderState fog_state() {
	ron::RenderState rs;
	rs.name = "Fog Overlay";
	rs.enables = 0x5;
	rs.src_blend = ron::BlendMode::SrcAlpha;
	rs.dst_blend = ron::BlendMode::InvSrcAlpha;
	rs.cull = ron::CullMode::None;
	rs.stage[0] = {ron::TextureOp::SelectArg1, ron::TextureArg::Texture, ron::TextureArg::Diffuse,
	               ron::TextureOp::SelectArg1, ron::TextureArg::Texture, ron::TextureArg::Diffuse, 0,
	               ron::TexAddress::Clamp, ron::TexAddress::Clamp};
	return rs;
}

// "Farm Blend" (Farms::init, a RenderState of its own): RenderState defaults plus enables |= 0x20084 (depth test and
// write, blend, alpha test with the default ALWAYS, fake light), SRCALPHA / INVSRCALPHA, stage 0 colour and alpha both
// MODULATE(TEXTURE, DIFFUSE). docs/farms-spec.md section 4.
static ron::RenderState farm_state() {
	ron::RenderState rs;
	rs.name = "Farm Blend";
	rs.enables = 0x20087;
	rs.src_blend = ron::BlendMode::SrcAlpha;
	rs.dst_blend = ron::BlendMode::InvSrcAlpha;
	rs.cull = ron::CullMode::CCW;
	rs.stage[0] = {ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current, 0,
	               ron::TexAddress::Wrap, ron::TexAddress::Wrap};
	return rs;
}

// River troughs ("trough_rs"): no depth test, blended, lit; colour and alpha = texture x diffuse.
static ron::RenderState trough_state() {
	ron::RenderState rs = land_state();
	rs.name = "River Trough";
	rs.enables = 0x204;
	rs.cull = ron::CullMode::None;
	rs.stage[0].alpha_op = ron::TextureOp::Modulate;
	rs.stage[0].alpha_arg1 = ron::TextureArg::Texture;
	rs.stage[0].alpha_arg2 = ron::TextureArg::Diffuse;
	return rs;
}

// River water sheen ("water_rs"): depth test without write, blended, unlit; the newwater frame x diffuse, alpha =
// diffuse x the RIVERTEX_WATER alpha on UV1.
static ron::RenderState river_water_state() {
	ron::RenderState rs = land_state();
	rs.name = "River Water";
	rs.enables = 0x5;
	rs.cull = ron::CullMode::None;
	rs.stage[1] = {ron::TextureOp::SelectArg2, ron::TextureArg::Texture, ron::TextureArg::Current,
	               ron::TextureOp::Modulate, ron::TextureArg::Texture, ron::TextureArg::Current, 1,
	               ron::TexAddress::Wrap, ron::TexAddress::Wrap};
	return rs;
}

static ron::RenderState water_state() {
	ron::RenderState rs = land_state();
	rs.name = "Terrain Water";
	rs.enables = ron::rs_enable::kDepthTest | ron::rs_enable::kAlphaBlend;
	rs.cull = ron::CullMode::None;
	rs.stage[0].color_op = ron::TextureOp::SelectArg2;
	return rs;
}

// Default unit team colours (TeamColors::init, TEAM_COLOR_UNIT_*), RGB 0..255.
static const uint8_t kUnitTeamColors[9][3] = {{255, 0, 0},   {34, 82, 255},  {255, 0, 255}, {0, 208, 0},   {255, 255, 0},
                                              {0, 255, 255}, {255, 255, 255}, {255, 105, 0}, {255, 255, 255}};

// Default building team colours (TeamColors::init, TEAM_COLOR_BUILD_*), RGB 0..255.
static const uint8_t kBuildTeamColors[9][3] = {{102, 0, 0},   {26, 57, 172}, {128, 0, 128}, {0, 89, 0},     {98, 96, 0},
                                               {0, 92, 108},  {120, 120, 120}, {112, 48, 0}, {255, 255, 255}};

// A loaded building graphic: sprite, depth hull (pre-mapped to building space) and add-on models.
struct BuildAsset {
	const ron::BuildGraphic* graphic = nullptr;
	id<MTLTexture> sprite;
	int sprite_w = 0, sprite_h = 0;
	std::vector<ron::ColorVertex> hull;  // building space: (-3y, -3x, 3z) of the BH3 rest pose
	std::vector<uint16_t> hull_indices;
	struct Addon {
		std::unique_ptr<ron::BH3Model> model;
		std::unique_ptr<ron::Animation> anim;
		id<MTLTexture> texture;
		const ron::RenderState* state = nullptr;
	};
	std::vector<Addon> addons;  // BUILD_DEFAULT events, in file order
};

// 3D units are drawn at unit scale x guy_scale (4.8, a global in riseofnations.exe) with the chad's Y mirror.
constexpr float kGuyScale = 4.8f;

struct PlacedUnit {
	int graphic = -1;
	float x = 0, y = 0, angle_deg = 0;
	int team = 1;
};

struct PlacedBuilding {
	std::string name;
	float x = 0, y = 0;
	int team = 1;
	BuildAsset* asset = nullptr;
	int who = -1, o = -1;  // the simulation's building (fog visibility), -1 for --build extras
};

// UnitAnim (CHAR_*) names by value (the PDB enum; re/analysis/types_unitanim.txt), as unit_graphics.xml spells them.
static const char* const kCharNames[] = {
	"CHAR_DEFAULT", "CHAR_IDLE1", "CHAR_IDLE2", "CHAR_IDLE3", "CHAR_GROUP_IDLE1", "CHAR_GROUP_IDLE2",
	"CHAR_GROUP_IDLE3", "CHAR_SLOG", "CHAR_WALK", "CHAR_JOG", "CHAR_ATTACKWALK", "CHAR_ATTACK1", "CHAR_ATTACK2",
	"CHAR_ATTACK3", "CHAR_ATTACKSPECIAL", "CHAR_DEATH_STAB1", "CHAR_DEATH_STAB2", "CHAR_DEATH_SHOT1",
	"CHAR_DEATH_SHOT2", "CHAR_DEATH_SPLODED1", "CHAR_DEATH_SPLODED2", "CHAR_TURN_LEFT", "CHAR_TURN_RIGHT",
	"CHAR_PACK", "CHAR_UNPACK", "CHAR_CHOP_WOOD", "CHAR_WALK_WITH_WOOD", "CHAR_DUMP_WOOD", "CHAR_WALK_TO_WOOD",
	"CHAR_MINE_ORE", "CHAR_WALK_WITH_ORE", "CHAR_DUMP_ORE", "CHAR_WALK_TO_ORE", "CHAR_BUILD", "CHAR_REPAIR",
	"CHAR_SOW", "CHAR_REAP", "CHAR_FARM"};
constexpr int kNumCharNames = int(sizeof kCharNames / sizeof kCharNames[0]);

// Wall-clock length of one simulation frame at the normal game speed (timings[2], docs/frame-spec.md section 1).
constexpr double kSimFrameMs = 67.0;

// One simulated figure as drawn this display frame (interpolated between the last two simulation frames).
struct SimFigure {
	int graphic = -1, anim = -1;  // unit graphic and clip index into its anims (-1: none)
	float x = 0, y = 0, angle_deg = 0;
	double clip_ms = 0;
	int team = 1;
	float scale = 1;  // set_unit_scale (ScriptPresentation::unit_scale by graphics piece)
};
// A projectile in flight or stuck in the ground (drawn with its effects_graphics.xml AMMO piece).
struct SimShot {
	std::string ammo;
	float x = 0, y = 0, z = 0, angle_deg = 0, pitch_deg = 0;
};
struct SimUnitDrawn {
	int32_t who = 0, o = 0;
	float x = 0, y = 0;  // the unit's interpolated position (selection)
	int32_t hp = 0, max_hp = 0;
	size_t first = 0, count = 0;  // its figures in _figures
	int32_t type = 0;
};

static int64_t sim_key(int32_t who, int32_t o, int32_t guy = 0) { return (int64_t(who) << 40) | (int64_t(o) << 16) | guy; }

// GameInfo difficulty from --difficulty (0 easiest .. 5; -1 keeps the default 2). AI armies only attack once they
// have enough standard units for the current military epoch (ai-spec find_target); in tut5 that takes difficulty 4.
static int g_difficulty = -1;
static std::optional<ron::sim::SkirmishSetup> g_skirmish;

// Debugging aid: RON_SKIP=floor,land,trans,coral,water skips those passes.
static bool debug_skip(const char* pass) {
	static const std::string skip = getenv("RON_SKIP") ? std::string(",") + getenv("RON_SKIP") + "," : std::string();
	return !skip.empty() && skip.find(std::string(",") + pass + ",") != std::string::npos;
}

@interface MapRenderer : NSObject <MTKViewDelegate>
@property(nonatomic, weak) MTKView* view;
@property(nonatomic) int zoom;
@property(nonatomic) BOOL bloom;
- (instancetype)initWithDevice:(id<MTLDevice>)device
                       gameDir:(NSString*)dir
                      scenario:(NSString*)scenario
                      simulate:(BOOL)simulate
                          seed:(uint32_t)seed
                         error:(NSString* __autoreleasing*)error;
- (void)lookAtX:(float)x y:(float)y;
- (BOOL)placeBuilding:(const std::string&)name x:(float)x y:(float)y team:(int)team;
- (BOOL)placeUnit:(const std::string&)name x:(float)x y:(float)y angle:(float)deg team:(int)team;
- (BOOL)snapshotTo:(NSString*)path width:(int)w height:(int)h scale:(float)scale;
- (void)advanceFarmsTo:(uint32_t)frame;
- (void)scrollByPixelsX:(float)dx y:(float)dy;
// Selection, in drawable pixels with a top-left origin. A rectangle of zero size picks the nearest unit.
- (void)selectInRect:(CGRect)r add:(BOOL)add;
- (void)selectAll;
- (void)handleKey:(NSEvent*)event;
// Simulation: MOVE_TO for the selection to the ground under a drawable pixel; scripted moves; stepping.
- (void)commandMoveAt:(CGPoint)p;
- (BOOL)issueMoveWho:(int)who objects:(const std::vector<int32_t>&)objs x:(int32_t)x y:(int32_t)y;
- (void)stepSimulation:(int)frames;
- (BOOL)issueAttackWho:(int)who objects:(const std::vector<int32_t>&)objs targetWho:(int)tw target:(int)to;
@property(nonatomic, readonly) BOOL simulating;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL fogOn;  // F toggles: off = everything visible (observer)
@property(nonatomic) BOOL hudOn;  // the in-game interface (--no-hud turns it off)
@property(nonatomic) float uiScale;  // drawable pixels per UI pixel: the window's backing scale (1 for snapshots)
// Input in UI pixels (view points, top-left origin): offered to the HUD first, then to the map (docs/ui-spec.md 4).
- (void)uiMouseDown:(CGPoint)p right:(BOOL)right modifiers:(NSEventModifierFlags)m clicks:(NSInteger)clicks;
- (void)uiMouseDragged:(CGPoint)p right:(BOOL)right delta:(CGPoint)d;
- (void)uiMouseUp:(CGPoint)p right:(BOOL)right modifiers:(NSEventModifierFlags)m;
- (void)uiMouseMoved:(CGPoint)p;
- (void)uiScrollWheel:(NSEvent*)e at:(CGPoint)p;
- (void)uiMagnify:(float)amount at:(CGPoint)p;
- (NSCursor*)cursorAt:(CGPoint)p;
// Headless helpers (snapshots): select objects of one owner; start placing a building and preview it at a world point.
- (BOOL)selectWho:(int)who objects:(const std::vector<int32_t>&)objs buildings:(BOOL)b;
- (void)startPlacement:(int)type;
- (void)previewPlacementAtWorldX:(float)x y:(float)y;
- (void)setBuildPage:(int)page;
- (void)placeAtWorldX:(float)wx y:(float)wy modifiers:(NSEventModifierFlags)m;
- (void)setLocalPlayer:(int)who;
- (void)queueWho:(int)who building:(int)o type:(int)type count:(int)n;
// Scenario scripts: the UI size for headless runs, script logging, a command-card click (OptionIndex, object) as the HUD
// runs it, the interactive start (audio, music), key state.
- (void)setUiWidth:(int)w height:(int)h scale:(float)scale;
- (void)setScriptLog:(BOOL)on;
- (void)runCardOption:(int)option object:(int)object;
- (void)startInteractive;
- (void)scriptKey:(NSEvent*)e down:(BOOL)down;
- (void)scriptFlags:(NSEventModifierFlags)m;
- (void)setMouseInside:(BOOL)inside;
- (void)setCursorWorldX:(float)x y:(float)y;
- (void)testPopup:(const char*)text;
// Leaving the game from the game menu or the game-over screen: quit = NO returns to the Main Menu. Nil: Quit only.
@property(nonatomic, copy) void (^onExit)(BOOL quit);
// Opens the game menu (Esc / F10): 1 the pause menu, 2 the game-over choices.
- (void)openGameMenu:(int)kind;
@end

// ---- HUD data adapter: the console player's numbers for the resource panel and the top strip, from the production view
// (sim::leader_view: stockpiles, population in use / cap, cities / limit, age). Income rates and the commerce cap belong
// to the economy port and are not exposed yet: they show 0 until then. TODO(economy view API).
static hud::Resources hud_resources(const ron::sim::Game* g, int who) {
	hud::Resources r;
	if (!g) return r;
	const ron::sim::LeaderView v = ron::sim::leader_view(*g, who);
	r.live = v.valid;
	for (size_t k = 0; k < 6; k++) {
		r.stock[k] = v.stockpile[k];  // indexed by good TypeIndex (food 0 ... oil 5)
		r.rate[k] = (v.income[k] + 8) / 16;  // draw_resource: (income + 8) / 16 (ui-spec, resource panel)
	}
	// draw_cap: the smallest commerce cap of the goods (resource_cap / 16; economy-spec 2.3).
	int cap = 999;
	for (size_t k = 0; k < 6; k++) {
		if (v.cap[k] > 0) cap = std::min(cap, v.cap[k] / 16);
	}
	r.commerce_cap = cap;
	r.pop = v.control;
	r.pop_cap = v.pop_cap;
	r.cities = v.cities;
	r.city_limit = v.city_limit;
	r.age = v.age;
	return r;
}

@implementation MapRenderer {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	rm::StateCache _states;
	rm::StateCache _overlayStates;  // post-tonemap overlays on the BGRA8 output (no depth)
	rm::PostProcess _post;
	rm::SceneTargets _targets;
	ron::RenderState _landState, _waterState, _treeState;
	id<MTLBuffer> _treeVB;
	id<MTLBuffer> _treeIB[ron::kTreeSlots];
	NSUInteger _treeCount[ron::kTreeSlots];
	id<MTLTexture> _treeTex[ron::kTreeSlots];
	// Trees under fog (RTreeData::adjust_tree_colors, fog-spec 9.3): hidden in unexplored cells, darkened where not seen.
	std::vector<ron::ColorVertex> _treeVerts;                // lit colours as built
	std::vector<uint32_t> _treeFirstVert;                    // per tree, + one end entry
	std::vector<int32_t> _treeFogCell;                       // per tree: fy * fog_xs + fx
	std::vector<uint32_t> _treeTris[ron::kTreeSlots];        // all triangles (3 indices each)
	std::vector<uint32_t> _treeTriTree[ron::kTreeSlots];     // the tree of each triangle
	std::vector<uint8_t> _treeLevel;                         // the fog level each tree was last drawn with

	std::string _title;
	ron::TerrainMesh _mesh;
	id<MTLBuffer> _landVB, _waterVB, _waterIB;
	std::vector<id<MTLBuffer>> _bucketIB;
	std::vector<id<MTLTexture>> _bucketTex;
	struct TransitionDraw {
		id<MTLBuffer> vb, ib;
		NSUInteger count;
		id<MTLTexture> texture, mask;
		bool ocean;
	};
	std::vector<TransitionDraw> _transitions;
	id<MTLTexture> _coral;
	id<MTLBuffer> _floorVB, _floorIB;
	struct MeshDraw {
		id<MTLBuffer> vb, ib;
		NSUInteger count;
		id<MTLTexture> tex0, tex1, tex0b, tex1b;  // b: the second draw (mountains)
	};
	std::vector<MeshDraw> _mountainDraws, _dooberDraws;
	MeshDraw _snowcapDraw;
	MeshDraw _farmUnderlays[2];  // "wheatfarm" and "pigfarm" ground (Weathering Underlay)
	std::vector<ron::Farm> _farms;
	ron::FarmParams _farmParams;
	id<MTLTexture> _farmTex;
	uint32_t _farmFrame, _farmSeed;
	// With the simulation, farms come from Game::farms (growth, type, construction): the sim's (who, o) per _farms entry.
	std::vector<std::pair<int32_t, int32_t>> _farmKeys;
	id<MTLTexture> _farmUnderTex[2];
	ron::WheatMesh _wheat;
	std::vector<MeshDraw> _troughDraws;
	MeshDraw _riverWaterDraw;
	id<MTLTexture> _floorTex;
	id<MTLTexture> _white;
	simd_float3 _lookAt;

	std::unique_ptr<ron::GameFiles> _files;
	ron::Terrain _terrain;
	ron::BuildCatalog _builds;
	ron::SceneLighting _lighting;
	float _terrainLight[3];
	ron::AmmoCatalog _ammo;
	std::map<std::string, std::unique_ptr<BuildAsset>> _buildAssets;
	// Construction (docs/buildings-spec.md section 6): underlay sprites and 3D scaffold pieces.
	std::vector<ron::ConstructionSprite> _constructSprites;
	std::map<size_t, id<MTLTexture>> _constructTex;
	std::map<size_t, int> _constructW, _constructH;
	ron::ScaffoldSet _scaffolds;
	struct ScaffoldModel {
		std::unique_ptr<ron::BH3Model> model;
		std::unique_ptr<ron::Animation> anim;
		id<MTLTexture> texture;
		const ron::RenderState* state = nullptr;
	};
	std::map<const ron::ScaffoldPiece*, std::unique_ptr<ScaffoldModel>> _scaffoldModels;
	std::vector<PlacedBuilding> _placed;
	rm::UnitDrawer _units;
	std::vector<PlacedUnit> _placedUnits;
	struct GoodAsset {
		std::unique_ptr<ron::BH3Model> model;
		std::unique_ptr<ron::Animation> anim;
		id<MTLTexture> texture;
		id<MTLBuffer> indices;
		std::vector<ron::PosedVertex> posed;
	};
	std::map<std::string, std::unique_ptr<GoodAsset>> _goodAssets;  // by GOOD name; null without a 3D model
	struct PlacedGood {
		GoodAsset* asset;
		float x, y;
	};
	std::vector<PlacedGood> _placedGoods;
	// Simulation (engine/sim): the scenario's units. Static _placedUnits keep turrets, farm animals and --unit extras.
	std::unique_ptr<ron::sim::Rules> _simRules;
	std::unique_ptr<ron::sim::AssetAnimSource> _art;  // animation lengths and graphics pieces (docs/anim-spec.md)
	std::unique_ptr<ron::sim::Game> _game;
	std::unordered_map<int32_t, int> _pieceGraphic;    // gpiece -> unit graphic (-1: unknown)
	ron::sim::CommandManager _cm;
	ron::sim::GameView _prevView, _curView;
	std::unordered_map<int64_t, size_t> _prevIndex;  // sim_key(who, o) -> index in _prevView.units
	std::map<std::pair<int, int>, int> _scenarioGraphic;  // (who, o) -> unit graphic from the scenario resolution
	std::map<int32_t, int> _typeGraphic;                 // sim type -> fallback graphic (units created in game)
	std::map<std::pair<int, int>, int> _clipIndex;       // (graphic, CHAR_*) -> clip index
	struct ClipClock {
		int anim = -1;
		double start_ms = 0;
	};
	std::unordered_map<int64_t, ClipClock> _clipClocks;  // per figure: when its current animation started
	double _simMs;                                       // wall-clock time since the last simulation step
	bool _simEnabled;
	uint32_t _simSeed;
	std::vector<SimFigure> _figures;
	// Fog of war (docs/fog-spec.md 9): levels for the local player per fog cell, the draped overlay and its ramp.
	ron::FogOverlay _fog;
	std::vector<uint8_t> _fogLevels;
	id<MTLBuffer> _fogVB, _fogIB;
	id<MTLTexture> _fogTex;
	bool _fogUploaded;
	ron::sim::FogView _fogView;
	std::vector<SimUnitDrawn> _drawnUnits;
	std::vector<SimShot> _shots;
	std::vector<std::pair<int32_t, int32_t>> _selected;  // (who, o) of selected simulated units
	simd_float3 _startCamera;
	bool _hasStartCamera;
	double _timeMs, _lastFrame;
	// Interface (docs/ui-spec.md, docs/ui-port.md).
	std::unique_ptr<ron::IfaceLayout> _layout;
	rm::UiRenderer _ui;
	hud::Hud _hud;
	std::map<int, NSCursor*> _cursors;
	id<MTLTexture> _miniBG, _miniFog;
	std::vector<uint8_t> _miniFogLevels;
	std::vector<simd_float2> _treeXY;
	std::vector<std::pair<int32_t, int32_t>> _selectedBuilds;  // selected buildings (never mixed with units)
	int _uiW, _uiH;
	hud::State _hudState;  // the last state handed to the HUD (input hit tests use it)
	// Mouse (UI pixels).
	CGPoint _press, _mouse;
	double _pressMs;
	BOOL _pressing, _boxing, _hudPress, _rightPress, _rightDragged;
	NSEventModifierFlags _pressMods;
	// Command modes.
	int _targeting;  // OptionIndex of a pending target mode (MOVE_TO / ATTACK_TO), -1 none
	int _buildPage;  // -1 unit orders; 0 civic, 1 military, 2 wonders (Options::set_mode BUILD_OPTIONS)
	int _placeType;  // building being placed, -1 none (docs/ui-spec.md 4.5)
	BOOL _ghostValid;
	float _ghostX, _ghostY;
	int32_t _ghostBlocked;
	// Control groups: seat-local until the simulation has the HOTKEY command (TODO(hotkey): replay-spec #34).
	struct ControlGroup {
		std::vector<std::pair<int32_t, int32_t>> units, builds;
		bool bookmark = false;
		simd_float3 at{};
		int zoom = 5;
	};
	ControlGroup _groups[10];
	int _lastGroupKey;
	double _lastGroupMs;
	float _magnify;
	NSInteger _pressClicks;
	CGFloat _drawW, _drawH;  // the drawable size of the frame being rendered
	// Scenario scripts (docs/ui-port.md "Script UI"): the presentation consumer, audio, the seat-local input.
	scriptview::View _sview;
	BOOL _sviewOn;
	std::unique_ptr<ron::audio::Audio> _audio;
	BOOL _headless;  // no window (snapshots, harness runs): a virtual clock of one frame per step, no audio
	BOOL _scriptLog;
	uint64_t _logSeq;
	size_t _logObjectives;
	std::vector<std::pair<std::string, int>> _logDone;
	struct CameraPan {  // Camera pan_to / to_zoom_level state, advanced by check_zoom steps
		int panning = 0, to_x = 0, to_y = 0, from_x = 0, from_y = 0;
		bool zooming = false;
		int to_zoom = 5;
	} _pan;
	double _camAccumMs;
	int _hiliteOverride;  // highlight_option(name) resolved through option_info, -1 none
	std::array<uint8_t, 256> _keys;  // Game::keystate by virtual key (bit 7 down)
	uint32_t _pendingWarnings;       // ScenarioData::user_warnings bits raised by the card since the last frame
	BOOL _mouseInside;
	BOOL _inPopup;
	int _popupResult;
	size_t _gameEventsSeen;
	// The game menu (MainMenuBase in interface.xml MAINMENU look): 0 closed, 1 Esc menu, 2 game over.
	int _gameMenu;
	std::vector<ron::IfaceRect> _gmRects;
	int _gmHover, _gmPress;
	double _overMs;  // when the local game-over was first seen (-1 not yet)
	BOOL _overOffered;
	BOOL _uiReady;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                       gameDir:(NSString*)dir
                      scenario:(NSString*)scenarioPath
                      simulate:(BOOL)simulate
                          seed:(uint32_t)seed
                         error:(NSString* __autoreleasing*)error {
	if (!(self = [super init])) return nil;
	_simEnabled = simulate;
	_fogOn = YES;
	_uiScale = 1;
	_targeting = -1, _buildPage = -1, _placeType = -1, _lastGroupKey = -1;
	_gmHover = _gmPress = -1, _overMs = -1;
	_simSeed = seed;
	_device = device;
	_queue = [device newCommandQueue];
	_zoom = 5;
	_bloom = YES;
	_landState = land_state();
	_waterState = water_state();
	_treeState = tree_state();
	std::string err;
	if (!_states.init(device, rm::SceneTargets::kColor, rm::SceneTargets::kDepth, err) ||
	    !_overlayStates.init(device, MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, err) ||
	    !_post.init(device, _states.library(), MTLPixelFormatBGRA8Unorm, err)) {
		*error = @(err.c_str());
		return nil;
	}
	try {
		_files = std::make_unique<ron::GameFiles>(dir.UTF8String);
		const ron::GameFiles& files = *_files;
		const auto anim_names = ron::load_anim_names(files);
		_builds = ron::load_build_catalog(files, anim_names);
		_constructSprites = ron::load_construction_sprites(files);
		_scaffolds = ron::load_scaffolds(files, anim_names);
		_lighting = ron::load_scene_lighting(files);
		_units.init(device, _queue, &_states, _files.get());
		const float* ua = _lighting.unit_ambient;
		const float* ud = _lighting.unit_diffuse;
		_units.set_unit_material(simd_make_float4(ua[0], ua[1], ua[2], 1), simd_make_float4(ud[0], ud[1], ud[2], 1));
		_ammo = ron::load_ammo_catalog(files, anim_names);
		std::string path = scenarioPath.UTF8String;
		if (!files.resolve(path).empty()) path = files.resolve(path);  // allow paths relative to the game dir
		ron::Scenario sc = ron::parse_scenario(ron::read_file(path));
		if (g_skirmish) {
			const auto setupRules = ron::sim::load_rules(files);
			ron::sim::configure_skirmish(sc, *g_skirmish, int(setupRules.tribes.size()));
		}
		const ron::Tileset ts = ron::load_tileset(files, sc.terrain.tileset);
		const std::vector<ron::TransitionMask> masks = ron::load_transition_masks(files);
		_mesh = ron::build_terrain_mesh(sc.terrain, ts, &masks, sc.world_seed);
		_terrain = sc.terrain;
		for (int c = 0; c < 3; c++) _terrainLight[c] = ts.diffuse[c];  // the Sun during the terrain pass: tileset DIFFUSE
		_title = sc.name + "  (" + std::to_string(sc.terrain.xs) + "x" + std::to_string(sc.terrain.ys) + ", " + ts.name + ")";
		std::printf("%s: %zu land vertices, %zu textures, %zu water triangles\n", _title.c_str(), _mesh.land.size(),
		            _mesh.buckets.size(), _mesh.water_indices.size() / 3);
		[self buildTrees:sc.terrain tileset:ts files:files];
		std::map<std::string, id<MTLTexture>> tex_cache;
		auto tex = [&](const std::string& rel) {
			auto it = tex_cache.find(rel);
			if (it != tex_cache.end()) return it->second;
			return tex_cache[rel] = [self makeTexture:ron::parse_tga(ron::read_file(files.resolve(rel)))];
		};
		size_t patches = 0;
		for (const ron::TransitionBucket& b : _mesh.transitions) {
			_transitions.push_back({[device newBufferWithBytes:b.vertices.data() length:b.vertices.size() * sizeof(ron::ColorVertex2) options:MTLResourceStorageModeShared],
			                        [device newBufferWithBytes:b.indices.data() length:b.indices.size() * 4 options:MTLResourceStorageModeShared],
			                        b.indices.size(), tex(b.texture), tex(b.mask), b.ocean});
			patches += b.vertices.size() / 25;
		}
		if (!ts.coral.empty()) _coral = tex(ts.coral);
		const ron::Dressing dressing = ron::build_dressing(files, ron::load_graphics_txt(files), sc.terrain, ts);
		auto buffer = [&](const void* data, size_t bytes) { return [device newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared]; };
		if (!ts.mountain_base.empty() && !ts.mountain_alpha.empty()) {
			for (const ron::MountainRangeMesh& m : dressing.mountains) {
				if (m.indices.empty() || files.resolve(m.ring_alpha).empty() || files.resolve(m.main_alpha).empty()) continue;
				_mountainDraws.push_back({buffer(m.vertices.data(), m.vertices.size() * sizeof(ron::ColorVertex2)),
				                          buffer(m.indices.data(), m.indices.size() * 4), m.indices.size(),
				                          tex(ts.mountain_alpha), tex(m.ring_alpha), tex(ts.mountain_base), tex(m.main_alpha)});
			}
		}
		if (!dressing.snowcap_indices.empty()) {
			_snowcapDraw = {buffer(dressing.snowcaps.data(), dressing.snowcaps.size() * sizeof(ron::ColorVertex2)),
			                buffer(dressing.snowcap_indices.data(), dressing.snowcap_indices.size() * 4), dressing.snowcap_indices.size(),
			                tex(ts.snowcap), tex(ts.snowcap), nil, nil};
		}
		size_t ndoobers = 0;
		for (const ron::DooberBatch& d : dressing.doobers) {
			_dooberDraws.push_back({buffer(d.vertices.data(), d.vertices.size() * sizeof(ron::ColorVertex)),
			                        buffer(d.indices.data(), d.indices.size() * 4), d.indices.size(), tex(d.texture), nil, nil, nil});
			ndoobers += d.vertices.size() / 4;
		}
		const ron::RiverMesh rivers = ron::build_rivers(sc.terrain);
		const std::string river_tex[3] = {ts.river_normal, ts.river_delta, ts.river_halfdelta};
		for (int i = 0; i < 3; i++) {
			if (rivers.trough_indices[i].empty() || river_tex[i].empty()) continue;
			_troughDraws.push_back({buffer(rivers.trough[i].data(), rivers.trough[i].size() * sizeof(ron::ColorVertex)),
			                        buffer(rivers.trough_indices[i].data(), rivers.trough_indices[i].size() * 4),
			                        rivers.trough_indices[i].size(), tex(river_tex[i]), nil, nil, nil});
		}
		const std::string newwater = "terrain art/newwater/water0000.tga";
		if (!rivers.water_indices.empty() && !ts.river_water.empty() && !files.resolve(newwater).empty()) {
			_riverWaterDraw = {buffer(rivers.water.data(), rivers.water.size() * sizeof(ron::ColorVertex2)),
			                   buffer(rivers.water_indices.data(), rivers.water_indices.size() * 4), rivers.water_indices.size(),
			                   tex(newwater), tex(ts.river_water), nil, nil};
		}
		std::printf("rivers: %zu river(s), %zu sections\n", sc.terrain.rivers.size(), rivers.water.size() / 4);
		std::printf("dressing: %zu mountain ranges, %zu snowcap vertices, %zu doobers\n", _mountainDraws.size(), dressing.snowcaps.size(), ndoobers);
		if (!_mesh.floor_indices.empty() && !_mesh.floor_texture.empty()) {
			_floorVB = [device newBufferWithBytes:_mesh.floor.data() length:_mesh.floor.size() * sizeof(ron::ColorVertex2) options:MTLResourceStorageModeShared];
			_floorIB = [device newBufferWithBytes:_mesh.floor_indices.data() length:_mesh.floor_indices.size() * 4 options:MTLResourceStorageModeShared];
			_floorTex = tex(_mesh.floor_texture);
		}
		std::printf("transitions: %zu patches in %zu batches\n", patches, _transitions.size());

		// The scenario's objects (docs/scenario-objects-spec.md): buildings, cities and units with their graphics.
		const std::string rel = path.rfind(files.root() + "/", 0) == 0 ? path.substr(files.root().size() + 1) : path;
		const ron::Battlefield bf = ron::resolve_battlefield(files, sc, rel, ron::load_rules(files),
		                                                     _builds, _units.units());
		if (_simEnabled) {
			try {
				_simRules = std::make_unique<ron::sim::Rules>(ron::sim::load_rules(files));
				ron::sim::GameSetup ruleSetup;
				if (g_skirmish) {
					ruleSetup.starting_technology = sc.start_tech;
					ruleSetup.ending_technology = sc.end_tech;
					ruleSetup.game_rules = sc.game_rules;
					ruleSetup.flag8 = (sc.scenario_flags & 4) != 0;
				}
				ron::sim::start_game(*_simRules, ruleSetup);
				_art = ron::sim::load_anim_source(files, *_simRules);
				_game = std::make_unique<ron::sim::Game>();
				_game->anims = _art.get();
				if (g_difficulty >= 0) _game->info.difficulty = uint8_t(g_difficulty);
				if (g_skirmish) ron::sim::configure_skirmish_info(_game->info, *g_skirmish);
				_game->load(files, sc, *_simRules, _simSeed);
				// Scenario, general powers and AI production scripts (sim/script_host.hpp).
				const ron::sim::ScriptLoadReport srep = ron::sim::script_host_load(*_game, files, path, sc);
				for (const std::string& e : srep.errors) std::fprintf(stderr, "script: %s\n", e.c_str());
				_curView = ron::sim::make_view(*_game);
				_prevView = _curView;
				[self indexPrevView];
			} catch (const std::exception& e) {
				if (g_skirmish) throw;
				std::fprintf(stderr, "simulation unavailable (%s); drawing the scenario's units where they stand\n", e.what());
				_game.reset();
			}
		}
		size_t nb = 0, nu = 0, nsim = 0;
		std::vector<ron::FarmSite> farm_sites;
		std::vector<ron::CitySite> city_sites;
		for (const ron::PlacedObject& o : bf.objects) {
			if (o.kind == ron::PlacedObject::Building && o.city) {
				const int level = o.graphic.rfind("METROPOLIS", 0) == 0 ? 3 : o.graphic.rfind("CITY", 0) == 0 ? 2 : 1;
				city_sites.push_back({o.x, o.y, o.who, level});
			}
			if (o.kind == ron::PlacedObject::Farm) farm_sites.push_back({o.x, o.y, o.who, o.slot});
			else if (o.kind == ron::PlacedObject::Good) [self placeGood:o.graphic x:o.x y:o.y files:files];
			else if (o.kind == ron::PlacedObject::Building) {
				if ([self placeBuilding:o.graphic x:o.x y:o.y team:o.color]) {
					nb++;
					for (PlacedBuilding& p : _placed) {
						if (p.x == o.x && p.y == o.y && p.who < 0) p.who = o.who, p.o = o.slot;
					}
				}
			}
			else if (_game && o.slot >= 0 && _units.find(o.graphic) >= 0) {
				_scenarioGraphic[{o.who, o.slot}] = _units.find(o.graphic);  // drawn where the simulation puts it
				nsim++;
			} else nu += [self placeUnit:o.graphic x:o.x y:o.y angle:o.angle_deg team:o.color] ? 1 : 0;
		}
		if (_game) std::printf("simulation: %zu scenario units bound, %zu simulated units alive\n", nsim, _curView.units.size());
		// Farms (docs/farms-spec.md): wheat boxes on a "wheatfarm" underlay, or an animal pen with five animals.
		_farmParams = ron::load_farm_params(files);
		_farms = ron::place_farms(sc.terrain, farm_sites, city_sites);
		_farmSeed = 1;
		const std::string farm_tex = !ts.farm_wheat.empty() ? ts.farm_wheat : (_builds.find("FARM") ? _builds.find("FARM")->texture : "");
		if (!farm_tex.empty() && !files.resolve(farm_tex).empty()) _farmTex = tex(farm_tex);
		size_t pens = 0;
		for (int k = 0; k < 2; k++) {
			const std::string& under = k == 0 ? ts.wheat_underlay : ts.animal_underlay;
			if (!under.empty() && !files.resolve(under).empty()) _farmUnderTex[k] = tex(under);
		}
		[self rebuildFarmUnderlays];
		for (const ron::Farm& f : _farms) {
			if (f.type != ron::FarmType::Animal) continue;
			pens++;
			if (_game) continue;  // the simulation creates the pen animals itself (Farms::add_animals)
			for (const ron::FarmAnimal& a : ron::farm_animals(f)) {
				const std::string name = a.type + "-TYPE" + std::to_string(a.variant);
				if (_units.find(name) >= 0) [self placeUnit:name x:a.x y:a.y angle:a.angle_deg team:8];
			}
		}
		std::printf("objects: %zu buildings, %zu units, %zu goods, %zu farms (%zu animal pens), %zu without a graphic\n", nb, nu,
		            _placedGoods.size(), _farms.size(), pens, bf.unresolved.size());
		for (size_t i = 0; i < 8; i++) {
			if (g_skirmish && int(i) != g_skirmish->human) continue;
			if (sc.camera_x[i] >= 0 && sc.camera_y[i] >= 0) {
				_startCamera = simd_make_float3(float(sc.camera_x[i]), float(sc.camera_y[i]), 0);
				_hasStartCamera = true;
				break;
			}
		}
		if (g_skirmish && !_hasStartCamera) {
			for (const auto& building : sc.buildings) {
				if (building.who != g_skirmish->human || !building.city) continue;
				_startCamera = simd_make_float3(float(building.cx), float(building.cy), 0);
				_hasStartCamera = true;
				break;
			}
		}
		if (!ts.fog.empty() && !files.resolve(ts.fog).empty()) {
			{
				// The ramp is sampled exactly by u (no mipmaps). Tilesets name fow_fade.tga or the stronger-falloff
				// fow_fade_dark.tga, whose "seen before" level (u 2/3) is almost clear (alpha 9).
				const ron::Image ramp = ron::parse_tga(ron::read_file(files.resolve(ts.fog)));
				MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
				                                                                             width:NSUInteger(ramp.width)
				                                                                            height:NSUInteger(ramp.height)
				                                                                         mipmapped:NO];
				d.usage = MTLTextureUsageShaderRead;
				_fogTex = [device newTextureWithDescriptor:d];
				[_fogTex replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(ramp.width), NSUInteger(ramp.height)) mipmapLevel:0
				             withBytes:ramp.rgba.data() bytesPerRow:NSUInteger(ramp.width) * 4];
			}
			ron::build_fog_overlay(sc.terrain, _fog);
			_fogLevels.assign(size_t(_fog.fxs) * size_t(_fog.fys), 3);
			_fogIB = buffer(_fog.indices.data(), _fog.indices.size() * 4);
			_fogVB = buffer(_fog.vertices.data(), _fog.vertices.size() * sizeof(ron::ColorVertex));
		}
		for (const ron::TerrainBucket& b : _mesh.buckets) {
			_bucketIB.push_back([device newBufferWithBytes:b.indices.data() length:b.indices.size() * 4 options:MTLResourceStorageModeShared]);
			_bucketTex.push_back([self makeTexture:ron::parse_tga(ron::read_file(files.resolve(b.texture)))]);
		}
	} catch (const std::exception& e) {
		*error = [NSString stringWithFormat:@"%s", e.what()];
		return nil;
	}
	_landVB = [device newBufferWithBytes:_mesh.land.data() length:_mesh.land.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	if (!_mesh.water_indices.empty()) {
		_waterVB = [device newBufferWithBytes:_mesh.water.data() length:_mesh.water.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
		_waterIB = [device newBufferWithBytes:_mesh.water_indices.data() length:_mesh.water_indices.size() * 4 options:MTLResourceStorageModeShared];
	}
	ron::Image white;
	white.width = white.height = 1;
	white.rgba = {255, 255, 255, 255};
	_white = [self makeTexture:white];
	_lookAt = _hasStartCamera ? _startCamera : simd_make_float3(_mesh.width / 2, _mesh.height / 2, 0);
	// The interface: layout, UI draw layer, HUD, cursors, the minimap background (docs/ui-port.md).
	try {
		_layout = std::make_unique<ron::IfaceLayout>(_files->read_text("Data/interface.xml"));
		std::string uerr;
		_hudOn = _ui.init(device, _queue, MTLPixelFormatBGRA8Unorm, _files.get(), _layout.get(), uerr) && _hud.init(*_files, *_layout, uerr);
		if (!_hudOn) std::fprintf(stderr, "interface unavailable: %s\n", uerr.c_str());
		_sviewOn = _hudOn && _sview.init(*_files, *_layout, uerr);
		_uiReady = _hudOn;
	} catch (const std::exception& e) {
		std::fprintf(stderr, "interface unavailable: %s\n", e.what());
		_hudOn = NO;
	}
	[self renderMinimapBackground];
	[self syncSimBuildings];
	_headless = YES;
	_hiliteOverride = -1;
	_keys.fill(0);
	if (_game) {
		if (ron::sim::ScriptInput* in = ron::sim::script_input(*_game)) {
			// BasePop::exec: popup_dialog / popup_choice block inside the script run until a button is chosen.
			__weak MapRenderer* weakSelf = self;
			in->popup = [weakSelf](const ron::sim::ScriptEvent& e) -> int32_t {
				MapRenderer* me = weakSelf;
				return me ? [me runPopup:e] : 0;
			};
		}
	}
	return self;
}

// Batches every tree into one vertex buffer (CPU-transformed rest poses) with an index list per texture slot.
- (void)buildTrees:(const ron::Terrain&)terrain tileset:(const ron::Tileset&)ts files:(const ron::GameFiles&)files {
	const ron::TreeSet set = ron::load_tree_set(files, ron::load_graphics_txt(files), ts);
	struct Model {
		std::vector<ron::PosedVertex> verts;
		std::vector<int> slot;  // per vertex
		std::vector<uint16_t> indices;
	};
	std::vector<Model> models;
	for (const std::string& path : set.models) {
		Model m;
		const ron::BH3Model bh3 = ron::parse_bh3(ron::read_file(files.resolve(path)));
		ron::pose_model(bh3, nullptr, 0, m.verts);
		m.slot.assign(m.verts.size(), -1);
		std::vector<const ron::BH3Node*> stack{&bh3.root};
		while (!stack.empty()) {
			const ron::BH3Node* n = stack.back();
			stack.pop_back();
			const int slot = ron::tree_slot_for_node(n->name);
			for (uint32_t v = n->first_vertex; v < n->first_vertex + n->vertex_count && v < m.slot.size(); v++) m.slot[v] = slot;
			for (const ron::BH3Node& c : n->children) stack.push_back(&c);
		}
		m.indices = bh3.meshes[0].indices;
		models.push_back(std::move(m));
	}
	const std::vector<ron::TreeInstance> trees = ron::place_trees(terrain, models.size());
	// Baked light for flat ground (as the terrain pass), at the tree's base.
	const float ndl = std::max(0.0f, -ron::kTerrainLightDir[2]);
	auto light = [&](int c) { return uint8_t(std::lround(std::clamp(ts.ambient[c] + ts.diffuse[c] * ndl, 0.0f, 1.0f) * 255)); };
	std::vector<ron::ColorVertex> verts;
	std::vector<uint32_t> idx[ron::kTreeSlots];
	const float s = set.scale;
	for (const ron::TreeInstance& t : trees) {
		const Model& m = models[size_t(t.model)];
		_treeXY.push_back(simd_make_float2(t.x, t.y));
		const uint32_t base = uint32_t(verts.size());
		_treeFirstVert.push_back(base);
		_treeFogCell.push_back(std::clamp(int(t.y / 384), 0, terrain.ys * 2 - 1) * terrain.xs * 2 +
		                       std::clamp(int(t.x / 384), 0, terrain.xs * 2 - 1));
		for (const ron::PosedVertex& p : m.verts) {
			verts.push_back({t.x + s * p.px, t.y - s * p.py, t.z + s * p.pz, p.nx, -p.ny, p.nz, p.u, p.v, light(0), light(1), light(2), 255});
		}
		for (size_t i = 0; i + 2 < m.indices.size(); i += 3) {
			const int slot = m.slot[m.indices[i]];
			if (slot < 0) continue;
			for (int k = 0; k < 3; k++) idx[slot].push_back(base + m.indices[i + size_t(k)]);
			_treeTriTree[slot].push_back(uint32_t(_treeFirstVert.size() - 1));
		}
	}
	_treeFirstVert.push_back(uint32_t(verts.size()));
	_treeVerts = verts;
	_treeLevel.assign(trees.size(), 3);
	std::printf("trees: %zu on %zu models\n", trees.size(), models.size());
	if (verts.empty()) return;
	_treeVB = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	for (int i = 0; i < ron::kTreeSlots; i++) {
		_treeCount[i] = idx[i].size();
		if (idx[i].empty() || set.textures[i].empty()) continue;
		_treeIB[i] = [_device newBufferWithBytes:idx[i].data() length:idx[i].size() * 4 options:MTLResourceStorageModeShared];
		_treeTris[i] = idx[i];
		_treeTex[i] = [self makeTexture:ron::parse_tga(ron::read_file(files.resolve(set.textures[i])))];
	}
}

- (id<MTLTexture>)makeTexture:(const ron::Image&)img {
	const bool mips = img.width > 1 || img.height > 1;
	MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
	                                                                             width:NSUInteger(img.width)
	                                                                            height:NSUInteger(img.height)
	                                                                         mipmapped:mips];
	d.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> t = [_device newTextureWithDescriptor:d];
	[t replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(img.width), NSUInteger(img.height)) mipmapLevel:0 withBytes:img.rgba.data() bytesPerRow:NSUInteger(img.width) * 4];
	if (mips) {
		id<MTLCommandBuffer> cb = [_queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit generateMipmapsForTexture:t];
		[blit endEncoding];
		[cb commit];
	}
	return t;
}

- (BOOL)placeBuilding:(const std::string&)name x:(float)x y:(float)y team:(int)team {
	BuildAsset* asset = [self buildAsset:name];
	if (!asset) {
		std::fprintf(stderr, "unknown or unloadable building graphic: %s\n", name.c_str());
		return NO;
	}
	_placed.push_back({name, x, y, std::clamp(team, 0, 8), asset});
	// Painter's order: back to front by x + y (ObjectsOut::sort_all).
	std::stable_sort(_placed.begin(), _placed.end(), [](const PlacedBuilding& a, const PlacedBuilding& b) { return a.x + a.y < b.x + b.y; });
	return YES;
}

- (BOOL)placeUnit:(const std::string&)name x:(float)x y:(float)y angle:(float)deg team:(int)team {
	const int g = _units.find(name);
	if (g < 0) {
		std::fprintf(stderr, "unknown unit graphic: %s\n", name.c_str());
		return NO;
	}
	_placedUnits.push_back({g, x, y, deg, std::clamp(team, 0, 8)});
	return YES;
}

// Units: translate(L) * rotate_z(angle) * scale(s, -s, s), s = unit scale x guy_scale (GuyOut::draw).
- (void)drawUnitGraphic:(int)graphic anim:(int)anim ms:(double)ms x:(float)x y:(float)y angle:(float)deg team:(int)team
                encoder:(id<MTLRenderCommandEncoder>)enc {
	[self drawUnitGraphic:graphic anim:anim ms:ms x:x y:y angle:deg team:team scale:1 encoder:enc];
}

- (void)drawUnitGraphic:(int)graphic anim:(int)anim ms:(double)ms x:(float)x y:(float)y angle:(float)deg team:(int)team
                  scale:(float)extra encoder:(id<MTLRenderCommandEncoder>)enc {
	const ron::UnitGraphic& g = _units.units()[size_t(graphic)];
	const float s = g.scale * kGuyScale * extra, a = deg * float(M_PI) / 180.0f;
	// Objects stand on the ground, but never below sea level: ships float at z = 0 over the sea floor.
	const float z = std::max(0.0f, _terrain.sample_height(x, y));
	const float c = std::cos(a), sn = std::sin(a);
	const simd_float4x4 world = simd_matrix(simd_make_float4(c * s, sn * s, 0, 0), simd_make_float4(sn * s, -c * s, 0, 0),
	                                        simd_make_float4(0, 0, s, 0), simd_make_float4(x, y, z, 1));
	const uint8_t* tc = kUnitTeamColors[std::clamp(team, 0, 8)];  // TeamColor::get_unit
	_units.draw(enc, graphic, anim, ms, world, simd_make_float4(tc[0], tc[1], tc[2], 255) / 255.0f, true);
}

- (void)encodeUnits:(id<MTLRenderCommandEncoder>)enc {
	[self encodeFlags:enc];
	for (const PlacedUnit& u : _placedUnits) [self drawUnitGraphic:u.graphic anim:0 ms:_timeMs x:u.x y:u.y angle:u.angle_deg team:u.team encoder:enc];
	for (const SimFigure& f : _figures)
		[self drawUnitGraphic:f.graphic anim:f.anim ms:f.clip_ms x:f.x y:f.y angle:f.angle_deg team:f.team scale:f.scale encoder:enc];
	// Projectiles at unit scale, oriented along the heading and pitched (an approximation of AmmoOut).
	for (const SimShot& sh : _shots) {
		const float s = kGuyScale, a = sh.angle_deg * float(M_PI) / 180.0f, pt = sh.pitch_deg * float(M_PI) / 180.0f;
		const simd_float4x4 T = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0),
		                                    simd_make_float4(sh.x, sh.y, sh.z, 1));
		const simd_float4x4 R = simd_matrix(simd_make_float4(std::cos(a), std::sin(a), 0, 0), simd_make_float4(-std::sin(a), std::cos(a), 0, 0),
		                                    simd_make_float4(0, 0, 1, 0), simd_make_float4(0, 0, 0, 1));
		const simd_float4x4 P = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, std::cos(pt), -std::sin(pt), 0),
		                                    simd_make_float4(0, std::sin(pt), std::cos(pt), 0), simd_make_float4(0, 0, 0, 1));
		const simd_float4x4 S = simd_matrix(simd_make_float4(s, 0, 0, 0), simd_make_float4(0, -s, 0, 0), simd_make_float4(0, 0, s, 0),
		                                    simd_make_float4(0, 0, 0, 1));
		_units.draw_ammo(enc, sh.ammo, _timeMs, simd_mul(T, simd_mul(R, simd_mul(P, S))), true);

	}
}

// Health bars over the selected units (ObjectsOut::draw_overlays, after tone mapping):
// a camera-facing strip above the unit, green for the remaining hit points over dark red.
- (void)encodeHealthBars:(id<MTLRenderCommandEncoder>)enc {
	if (_selected.empty()) return;
	static const ron::RenderState& bar_rs = *ron::find_render_state("Circle Blend");
	std::vector<ron::ColorVertex> verts;
	for (const SimUnitDrawn& u : _drawnUnits) {
		if (u.max_hp <= 0 || std::find(_selected.begin(), _selected.end(), std::make_pair(u.who, u.o)) == _selected.end()) continue;
		const float frac = std::clamp(float(u.hp) / float(u.max_hp), 0.0f, 1.0f);
		// A fixed on-screen size (28 x 4 pixels), 34 pixels above the unit's feet.
		const float upp = units_per_pixel(_zoom, float(_targets.hdr().width));
		const simd_float3 c = simd_make_float3(u.x, u.y, std::max(0.0f, _terrain.sample_height(u.x, u.y))) + kUp * (34.0f * upp);
		const float w = 28 * upp, h = 4 * upp;
		auto quad = [&](float x0, float x1, uint8_t r, uint8_t g, uint8_t b) {
			auto v = [&](float x, float y) {
				const simd_float3 p = c + kRight * x + kUp * y;
				return ron::ColorVertex{p.x, p.y, p.z, 0, 0, 1, 0, 0, r, g, b, 255};
			};
			const ron::ColorVertex q[6] = {v(x0, h), v(x1, h), v(x0, 0), v(x0, 0), v(x1, h), v(x1, 0)};
			verts.insert(verts.end(), q, q + 6);
		};
		quad(-w / 2, -w / 2 + w * frac, 40, 220, 40);
		if (frac < 1) quad(-w / 2 + w * frac, w / 2, 120, 0, 0);
	}
	if (verts.empty()) return;
	rm::DrawUniforms du = rm::draw_uniforms(bar_rs, matrix_identity_float4x4);
	_overlayStates.bind(enc, bar_rs, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_white atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:verts.size()];
}

// ---------------------------------------------------------------- simulation

- (BOOL)simulating {
	return _game != nullptr;
}

- (void)indexPrevView {
	_prevIndex.clear();
	for (size_t i = 0; i < _prevView.units.size(); i++) _prevIndex[sim_key(_prevView.units[i].who, _prevView.units[i].o)] = i;
}

// One simulation frame per iteration: execute the commands issued since the last step, then Game::do_frame
// (docs/frame-spec.md section 2). The renderer only reads the views.
- (void)stepSimulation:(int)frames {
	if (!_game) return;
	for (int i = 0; i < frames; i++) {
		if (_headless) {
			_timeMs += kSimFrameMs;  // the virtual clock: graphic ticks advance with the frames
			[self cameraStep:kSimFrameMs];
		}
		_cm.process_turn(*_game);
		[self fillScriptInput];
		_game->do_frame();
		[self consumeScript];
		_prevView = std::move(_curView);
		[self indexPrevView];
		_curView = ron::sim::make_view(*_game);
	}
	if (frames > 0) [self syncSimBuildings];
}

// GROUP + MOVE_TO from leader `who`'s seat, executed at once (several process_turn calls per frame are allowed; each
// package is stamped with one seat, so one owner per call).
- (BOOL)issueMoveWho:(int)who objects:(const std::vector<int32_t>&)objs x:(int32_t)x y:(int32_t)y {
	if (!_game) return NO;
	_cm.play = who;
	_cm.play_who = who;
	if (!_cm.issue_move_to(*_game, objs, x, y)) return NO;
	_cm.process_turn(*_game);
	return YES;
}

// The ground point under a drawable pixel: invert screenOf on the terrain (a few fixed-point steps for the height).
- (simd_float2)groundAt:(CGPoint)p {
	const CGSize size = [self drawSize];
	const float upp = units_per_pixel(_zoom, float(size.width));
	const float R = (float(p.x) - float(size.width) / 2) * upp, U = (float(size.height) / 2 - float(p.y)) * upp;
	float h = 0, x = _lookAt.x, y = _lookAt.y;
	for (int it = 0; it < 4; it++) {
		const float diff = R / kRight.x;                          // dx - dy
		const float sum = (kUp.z * (h - _lookAt.z) - U) / -kUp.x;  // dx + dy
		x = _lookAt.x + (sum + diff) / 2;
		y = _lookAt.y + (sum - diff) / 2;
		h = std::max(0.0f, _terrain.sample_height(std::clamp(x, 0.0f, _mesh.width), std::clamp(y, 0.0f, _mesh.height)));
	}
	return simd_make_float2(x, y);
}

- (void)commandMoveAt:(CGPoint)p {
	if (!_game || _selected.empty()) return;
	if ([self commandAttackAt:p]) return;
	const simd_float2 g = [self groundAt:p];
	const int32_t x = int32_t(std::lround(std::clamp(g.x, 0.0f, _mesh.width - 1))),
	              y = int32_t(std::lround(std::clamp(g.y, 0.0f, _mesh.height - 1)));
	std::map<int32_t, std::vector<int32_t>> by_owner;
	for (const auto& [who, o] : _selected) by_owner[who].push_back(o);
	for (const auto& [who, objs] : by_owner) [self issueMoveWho:who objects:objs x:x y:y];
	std::printf("move %zu unit(s) to (%d, %d) at frame %d\n", _selected.size(), x, y, _game->frame);
}

// Right-click on a drawn unit or building of another player: ATTACK for each owner's selected units that are at war
// with it. Returns false when nothing hostile is under the cursor.
- (BOOL)commandAttackAt:(CGPoint)p {
	int32_t tw = -1, to = -1;
	float best = 30;  // pixels
	for (const SimUnitDrawn& d : _drawnUnits) {
		const simd_float3 base = simd_make_float3(d.x, d.y, std::max(0.0f, _terrain.sample_height(d.x, d.y)));
		const float dist = simd_distance([self screenOf:base + simd_make_float3(0, 0, 60)], simd_make_float2(float(p.x), float(p.y)));
		if (dist < best) best = dist, tw = d.who, to = d.o;
	}
	if (tw < 0) {
		const simd_float2 g = [self groundAt:p];
		float bestw = 450;  // world units from the footprint centre
		for (const PlacedBuilding& b : _placed) {
			if (b.who < 0) continue;
			if (_fogOn && !ron::sim::build_seen_by(*_game, _game->local_play, b.who, b.o)) continue;
			const float dist = simd_distance(g, simd_make_float2(b.x, b.y));
			if (dist < bestw) bestw = dist, tw = b.who, to = b.o;
		}
	}
	if (tw < 0) return NO;
	std::map<int32_t, std::vector<int32_t>> by_owner;
	for (const auto& [who, o] : _selected) {
		if (ron::sim::is_enemy(*_game, who, tw)) by_owner[who].push_back(o);
	}
	if (by_owner.empty()) return NO;
	for (const auto& [who, objs] : by_owner) {
		_cm.play = who;
		_cm.play_who = who;
		if (_cm.issue_attack(*_game, objs, to, tw)) _cm.process_turn(*_game);
	}
	std::printf("attack %d:%d with %zu owner group(s) at frame %d\n", tw, to, by_owner.size(), _game->frame);
	return YES;
}

- (BOOL)issueAttackWho:(int)who objects:(const std::vector<int32_t>&)objs targetWho:(int)tw target:(int)to {
	if (!_game) return NO;
	_cm.play = who;
	_cm.play_who = who;
	if (!_cm.issue_attack(*_game, objs, to, tw)) return NO;
	_cm.process_turn(*_game);
	return YES;
}

// The unit graphic of a simulated unit: the scenario's resolution for units loaded from the file, else the type's
// DEFAULT style graphic (units created during play).
- (int)graphicForUnit:(const ron::sim::UnitView&)u {
	auto it = _scenarioGraphic.find({u.who, u.o});
	if (it != _scenarioGraphic.end()) return it->second;
	auto t = _typeGraphic.find(u.type);
	if (t != _typeGraphic.end()) return t->second;
	const std::string base = ron::sim::to_utf8(_game->type(u.type).graph_name);
	int g = -1;
	for (const char* age : {"-DEFAULT-AGE0", "-DEFAULT-AGE3", "-DEFAULT-AGE5", ""}) {
		if ((g = _units.find(base + age)) >= 0) break;
	}
	return _typeGraphic[u.type] = g;
}

// The unit graphic of a guy's graphics piece (the <UNIT> name the original draws), else `fallback`.
- (int)graphicForPiece:(int32_t)piece fallback:(int)fallback {
	if (!_art || piece < 0) return fallback;
	auto it = _pieceGraphic.find(piece);
	if (it == _pieceGraphic.end()) {
		const std::string name = _art->piece_name(piece);
		it = _pieceGraphic.emplace(piece, name.empty() ? -1 : _units.find(name)).first;
		if (it->second < 0 && !name.empty()) std::fprintf(stderr, "graphics piece %d (%s): no unit graphic\n", piece, name.c_str());
	}
	return it->second >= 0 ? it->second : fallback;
}

// The clip of `graphic` for animation `anim` (CHAR_*), with fallbacks for animations a graphic does not have.
- (int)clipFor:(int)graphic anim:(int)anim {
	const auto key = std::make_pair(graphic, anim);
	auto it = _clipIndex.find(key);
	if (it != _clipIndex.end()) return it->second;
	const std::vector<ron::UnitAnim>& anims = _units.units()[size_t(graphic)].anims;
	auto find = [&](const char* name) {
		for (size_t i = 0; i < anims.size(); i++) {
			if (anims[i].action == name && !anims[i].file.empty()) return int(i);
		}
		return -1;
	};
	int idx = anim >= 0 && anim < kNumCharNames ? find(kCharNames[anim]) : -1;
	if (idx < 0 && anim >= 7 && anim <= 10) {  // SLOG, WALK, JOG, ATTACKWALK
		for (const char* n : {"CHAR_WALK", "CHAR_JOG", "CHAR_SLOG"}) {
			if ((idx = find(n)) >= 0) break;
		}
	}
	if (idx < 0 && anim >= 4 && anim <= 6) idx = find("CHAR_IDLE1");  // GROUP_IDLE*
	if (idx < 0) idx = find("CHAR_DEFAULT");
	if (idx < 0) idx = anims.empty() ? -1 : 0;
	return _clipIndex[key] = idx;
}

// Fog levels for the local player (0 unexplored, 1 explored, 2 seen before, 3 visible) from the simulation's fog
// (make_fog_view); everything visible with fog off or without the simulation. Test patterns: RON_FOG_TEST=1 (around
// units), RON_FOG_LEVEL=N (all cells at N) or =MN (a checker of levels M and N).
- (void)updateFog {
	if (!_fogVB) return;
	std::vector<uint8_t> levels(_fogLevels.size(), 3);
	if (_game && _fogOn && !getenv("RON_FOG_TEST") && !getenv("RON_FOG_LEVEL")) {
		ron::sim::make_fog_view(*_game, _game->local_play, _fogView);
		if (_fogView.fog_xs == _fog.fxs && _fogView.fog_ys == _fog.fys) levels = _fogView.level;
	} else if (getenv("RON_FOG_LEVEL")) {
		// "N": every cell at level N; "MN": a checker of 6-cell squares at levels M and N.
		const char* v = getenv("RON_FOG_LEVEL");
		for (int fy = 0; fy < _fog.fys; fy++) {
			for (int fx = 0; fx < _fog.fxs; fx++) {
				const bool odd = v[1] && ((fx / 6 + fy / 6) & 1);
				levels[size_t(fy * _fog.fxs + fx)] = uint8_t((odd ? v[1] : v[0]) - '0');
			}
		}
	} else if (getenv("RON_FOG_TEST")) {
		std::fill(levels.begin(), levels.end(), 0);
		for (int fy = 0; fy < _fog.fys; fy++) {
			for (int fx = 0; fx < _fog.fxs; fx++) {
				if ((fx / 6 + fy / 6) % 2) levels[size_t(fy * _fog.fxs + fx)] = 1;
			}
		}
		for (const SimUnitDrawn& d : _drawnUnits) {
			const int cx = int(d.x / 384), cy = int(d.y / 384);
			for (int dy = -6; dy <= 6; dy++) {
				for (int dx = -6; dx <= 6; dx++) {
					const int fx = cx + dx, fy = cy + dy;
					if (fx < 0 || fy < 0 || fx >= _fog.fxs || fy >= _fog.fys) continue;
					const int r2 = dx * dx + dy * dy;
					uint8_t& l = levels[size_t(fy * _fog.fxs + fx)];
					if (r2 <= 36) l = std::max<uint8_t>(l, r2 <= 16 ? 3 : 2);
				}
			}
		}
	}
	if (levels == _fogLevels && _fogUploaded) return;
	_fogLevels = std::move(levels);
	ron::update_fog_overlay(_fog, _fogLevels.data());
	std::memcpy(_fogVB.contents, _fog.vertices.data(), _fog.vertices.size() * sizeof(ron::ColorVertex));
	_fogUploaded = true;
	[self applyFogToTrees];
}

// Trees in unexplored cells are not drawn; trees in cells not currently seen are darkened (DARK_GREY instead of the
// normal GREY diffuse: half the colour).
- (void)applyFogToTrees {
	if (!_treeVB || _treeLevel.empty() || _fogLevels.empty()) return;
	bool visible = false;
	ron::ColorVertex* vb = static_cast<ron::ColorVertex*>(_treeVB.contents);
	for (size_t t = 0; t < _treeLevel.size(); t++) {
		const uint8_t l = _fogLevels[size_t(_treeFogCell[t])];
		if (l == _treeLevel[t]) continue;
		if ((l == 0) != (_treeLevel[t] == 0)) visible = true;
		if ((l == 3) != (_treeLevel[t] == 3)) {
			const int k = l == 3 ? 2 : 1;  // x 1 or x 1/2
			for (uint32_t v = _treeFirstVert[t]; v < _treeFirstVert[t + 1]; v++) {
				const ron::ColorVertex& src = _treeVerts[v];
				vb[v].r = uint8_t(src.r * k / 2), vb[v].g = uint8_t(src.g * k / 2), vb[v].b = uint8_t(src.b * k / 2);
			}
		}
		_treeLevel[t] = l;
	}
	if (!visible) return;
	for (int i = 0; i < ron::kTreeSlots; i++) {
		if (!_treeIB[i]) continue;
		uint32_t* ib = static_cast<uint32_t*>(_treeIB[i].contents);
		size_t n = 0;
		for (size_t tri = 0; tri < _treeTriTree[i].size(); tri++) {
			if (_treeLevel[_treeTriTree[i][tri]] == 0) continue;
			std::memcpy(ib + n, &_treeTris[i][tri * 3], 12);
			n += 3;
		}
		_treeCount[i] = n;
	}
}

// The local player's fog level (0..3) at a world position; 3 without fog data.
- (int)fogLevelAtX:(float)x y:(float)y {
	if (_fogLevels.empty() || !_fogUploaded) return 3;
	const int fx = std::clamp(int(x / 384), 0, _fog.fxs - 1), fy = std::clamp(int(y / 384), 0, _fog.fys - 1);
	return _fogLevels[size_t(fy) * size_t(_fog.fxs) + size_t(fx)];
}

- (void)encodeFog:(id<MTLRenderCommandEncoder>)enc {
	if (!_fogVB || debug_skip("fog")) return;
	static const ron::RenderState fog_rs = fog_state();
	rm::DrawUniforms du = rm::draw_uniforms(fog_rs, matrix_identity_float4x4);
	_states.bind(enc, fog_rs, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	[enc setVertexBuffer:_fogVB offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_fogTex atIndex:0];
	[enc setFragmentTexture:_fogTex atIndex:1];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_fog.indices.size() indexType:MTLIndexTypeUInt32
	               indexBuffer:_fogIB indexBufferOffset:0];
}

// Interpolates the last two simulation frames by the time since the last step (graphic_percent).
- (void)buildFigures {
	_figures.clear();
	_drawnUnits.clear();
	if (!_game) return;
	const float t = float(std::clamp(_simMs / kSimFrameMs, 0.0, 1.0));
	auto mix = [t](int32_t a, int32_t b) { return float(a) + float(b - a) * t; };
	auto angle = [t](uint32_t a, uint32_t b) {
		const double v = double(a) + double(int32_t(b - a)) * double(t);  // the short way round
		return float(v * 360.0 / 4294967296.0) + 180.0f;                  // GuyOut::draw adds 180 degrees
	};
	for (const ron::sim::UnitView& u : _curView.units) {
		if (!u.alive || !u.on_map) continue;
		if (_fogOn && !(u.seen_by & (1u << (_game->local_play & 7)))) continue;  // GraphicPieces::draw_unit: is_seen
		const int g = [self graphicForUnit:u];
		if (g < 0) continue;
		auto pi = _prevIndex.find(sim_key(u.who, u.o));
		const ron::sim::UnitView& p = pi != _prevIndex.end() ? _prevView.units[pi->second] : u;
		SimUnitDrawn d{u.who, u.o, mix(p.x, u.x), mix(p.y, u.y), u.hit_points, u.max_hit_points, _figures.size(), 0, u.type};
		const size_t n = std::max<size_t>(1, u.guys.size());
		for (size_t k = 0; k < n; k++) {
			ron::sim::GuyView cur{u.x, u.y, u.z, u.angle, 0}, prev{p.x, p.y, p.z, p.angle, 0};
			if (k < u.guys.size()) cur = u.guys[k];
			prev = k < p.guys.size() ? p.guys[k] : cur;
			SimFigure f;
			f.graphic = [self graphicForPiece:cur.gpiece fallback:g];
			f.x = mix(prev.x, cur.x);
			f.y = mix(prev.y, cur.y);
			f.angle_deg = angle(prev.angle, cur.angle);
			f.anim = [self clipFor:f.graphic anim:cur.anim];
			if (cur.end_time > 0 && f.anim >= 0) {
				// The sim's animation clock: frame cur_time of end_time, plus the interpolation fraction.
				const double len = _units.clip_ms(f.graphic, f.anim);
				f.clip_ms = std::min(1.0, (double(cur.cur_time) + double(t)) / double(cur.end_time)) * len;
				if (f.clip_ms >= len && len > 0) f.clip_ms = len - 0.5;  // hold the last pose, do not wrap
			} else {
				ClipClock& c = _clipClocks[sim_key(u.who, u.o, int32_t(k))];
				if (c.anim != cur.anim) c.anim = cur.anim, c.start_ms = _timeMs;
				f.clip_ms = _timeMs - c.start_ms;
			}
			f.team = u.color;
			if (const ron::sim::ScriptPresentation* sp = [self pres]) {
				auto us = sp->unit_scale.find(cur.gpiece);
				if (us != sp->unit_scale.end()) f.scale = us->second;
			}
			_figures.push_back(f);
		}
		d.count = _figures.size() - d.first;
		_drawnUnits.push_back(d);
	}
	// Corpses: the death animation, then its last pose until the corpse expires (combat-spec 6). Hidden where the
	// player does not see the cell now (deaths are skipped by is_seen of their cell, fog-spec 9.3).
	for (const ron::sim::CorpseView& c : _curView.corpses) {
		if (_fogOn && [self fogLevelAtX:float(c.x) y:float(c.y)] < 3) continue;
		SimFigure f;
		f.graphic = [self graphicForPiece:c.gpiece fallback:-1];
		if (f.graphic < 0) continue;
		f.x = float(c.x), f.y = float(c.y);
		f.angle_deg = float(double(c.angle) * 360.0 / 4294967296.0) + 180.0f;
		f.anim = [self clipFor:f.graphic anim:c.anim];
		const double len = f.anim >= 0 ? _units.clip_ms(f.graphic, f.anim) : 0;
		f.clip_ms = c.anim_frames > 0 ? std::min(1.0, (double(c.frame) + double(t)) / double(c.anim_frames)) * len : len;
		if (len > 0 && f.clip_ms >= len) f.clip_ms = len - 0.5;
		f.team = 8;
		for (const ron::sim::UnitView& u : _curView.units) {
			if (u.who == c.who) {
				f.team = u.color;
				break;
			}
		}
		_figures.push_back(f);
	}
	// Projectiles: heading from the shot, pitch from the launch-to-aim slope (AmmoOut::draw is not decoded).
	_shots.clear();
	for (const ron::sim::ProjectileView& pv : _curView.projectiles) {
		if (_fogOn && [self fogLevelAtX:float(pv.x) y:float(pv.y)] < 3) continue;
		SimShot sh;
		sh.ammo = _art ? _art->ammo_name(pv.ammo) : std::string();
		if (sh.ammo.empty()) continue;
		sh.x = float(pv.x), sh.y = float(pv.y), sh.z = float(pv.z);
		sh.angle_deg = float(double(pv.angle) * 360.0 / 4294967296.0);  // ammo models point the other way from units
		const float dx = float(pv.ex - pv.sx), dy = float(pv.ey - pv.sy), dz = float(pv.ez - pv.sz);
		sh.pitch_deg = pv.stuck ? 30.0f : std::atan2(dz, std::max(1.0f, std::sqrt(dx * dx + dy * dy))) * 57.29578f;
		_shots.push_back(sh);
	}
}

// The farm ground meshes (wheat field / animal pen underlays) for the current _farms.
- (void)rebuildFarmUnderlays {
	for (int k = 0; k < 2; k++) {
		_farmUnderlays[k] = MeshDraw{};
		const ron::FarmType type = k == 0 ? ron::FarmType::Wheat : ron::FarmType::Animal;
		ron::UnderlayMesh m;
		ron::build_farm_underlays(_terrain, _farms, type, m);
		if (m.indices.empty() || !_farmUnderTex[k]) continue;
		_farmUnderlays[k] = {[_device newBufferWithBytes:m.vertices.data() length:m.vertices.size() * sizeof(ron::ColorVertex2) options:MTLResourceStorageModeShared],
		                     [_device newBufferWithBytes:m.indices.data() length:m.indices.size() * 4 options:MTLResourceStorageModeShared],
		                     m.indices.size(), _farmUnderTex[k], _farmUnderTex[k], nil, nil};
	}
}

// Farms follow the simulation (Game::farms): the set is rebuilt when farms are added or removed (with the sim's
// wheat / pen choice), and every frame the growth, status and construction progress are copied for drawing.
- (void)syncSimFarms {
	if (!_game) return;
	std::vector<std::pair<int32_t, int32_t>> keys;
	std::vector<ron::FarmSite> sites;
	std::vector<const ron::sim::FarmRec*> recs;
	for (const ron::sim::FarmRec& r : _game->farms) {
		if (!r.valid) continue;
		const ron::sim::Build* b = _game->build(r.who, r.o);
		if (!b) continue;
		keys.push_back({r.who, r.o});
		sites.push_back({float(b->x), float(b->y), r.who, r.o});
		recs.push_back(&r);
	}
	if (keys != _farmKeys) {
		_farmKeys = keys;
		_farms = ron::place_farms(_terrain, sites, {});
		for (size_t i = 0; i < _farms.size() && i < recs.size(); i++)
			_farms[i].type = (recs[i]->farm_type & 1) ? ron::FarmType::Animal : ron::FarmType::Wheat;
		[self rebuildFarmUnderlays];
	}
	for (size_t i = 0; i < _farms.size() && i < recs.size(); i++) {
		ron::Farm& f = _farms[i];
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				f.percent[x][y] = recs[i]->percent[size_t(x)][size_t(y)];
				f.status[x][y] = recs[i]->status[size_t(x)][size_t(y)];
			}
		}
		const ron::sim::BuildView* bv = [self buildView:keys[i].first o:keys[i].second];
		f.build = bv && !bv->active && bv->max_hit_points > 0 ? float(bv->hit_points) / float(bv->max_hit_points) : 1.0f;
	}
	_farmFrame = uint32_t(_game->frame);
}

// Wheat (FarmsOut::draw): rebuilt every frame from the growth state and the wind phase, after the objects.
- (void)encodeWheat:(id<MTLRenderCommandEncoder>)enc {
	[self syncSimFarms];
	if (!_farmTex || _farms.empty()) return;
	if (_fogUploaded && _fogOn) {
		// Farms in unexplored cells are not drawn.
		std::vector<ron::Farm> seen;
		for (const ron::Farm& f : _farms) {
			if ([self fogLevelAtX:f.cx y:f.cy] > 0) seen.push_back(f);
		}
		ron::build_wheat(seen, _farmParams, _farmFrame, _wheat);
	} else {
		ron::build_wheat(_farms, _farmParams, _farmFrame, _wheat);
	}
	if (_wheat.indices.empty()) return;
	static const ron::RenderState farm_rs = farm_state();
	rm::DrawUniforms du = rm::draw_uniforms(farm_rs, matrix_identity_float4x4);
	_states.bind(enc, farm_rs, rm::VertexKind::Colored);
	id<MTLBuffer> vb = [_device newBufferWithBytes:_wheat.vertices.data() length:_wheat.vertices.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	id<MTLBuffer> ib = [_device newBufferWithBytes:_wheat.indices.data() length:_wheat.indices.size() * 4 options:MTLResourceStorageModeShared];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_farmTex atIndex:0];
	[enc setFragmentTexture:_farmTex atIndex:1];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_wheat.indices.size() indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0];
}

// Goods (resources) with a 3D model (effects_graphics.xml <GOOD model=.bh3>). Billboard and underlay goods (oil, fish)
// are not drawn yet.
- (void)placeGood:(const std::string&)name x:(float)x y:(float)y files:(const ron::GameFiles&)files {
	auto it = _goodAssets.find(name);
	if (it == _goodAssets.end()) {
		std::unique_ptr<GoodAsset> a;
		const ron::XmlElement* found = nullptr;
		static const ron::XmlElement effects = ron::parse_xml(files.read_text("Data/effects_graphics.xml"));
		ron::for_each_element(effects, "GOOD", [&](const ron::XmlElement& e) {
			if (!found && e.get("name") == name) found = &e;
		});
		const std::string model = found ? ron::normalize_game_path(found->get("model")) : std::string();
		if (!model.empty() && !files.resolve(model).empty()) {
			try {
				a = std::make_unique<GoodAsset>();
				a->model = std::make_unique<ron::BH3Model>(ron::parse_bh3(ron::read_file(files.resolve(model))));
				const std::string tex = ron::normalize_game_path(found->get("texture"));
				a->texture = tex.empty() || files.resolve(tex).empty() ? _white : [self makeTexture:ron::parse_tga(ron::read_file(files.resolve(tex)))];
				const auto& ix = a->model->meshes[0].indices;
				if (!ix.empty()) a->indices = [_device newBufferWithBytes:ix.data() length:ix.size() * 2 options:MTLResourceStorageModeShared];
			} catch (const std::exception& e) {
				std::fprintf(stderr, "good %s: %s\n", name.c_str(), e.what());
				a.reset();
			}
		}
		it = _goodAssets.emplace(name, std::move(a)).first;
	}
	if (it->second && it->second->indices) _placedGoods.push_back({it->second.get(), x, y});
}

// Goods draw like building add-ons: rotate_z(270) * translate * scale(3, -3, 3), i.e. L + (-3y, -3x, 3z), "Good Blend".
- (void)encodeGoods:(id<MTLRenderCommandEncoder>)enc {
	static const ron::RenderState& good_rs = *ron::find_render_state("Good Blend");
	for (PlacedGood& g : _placedGoods) {
		if (_fogOn && [self fogLevelAtX:g.x y:g.y] == 0) continue;  // goods in unexplored cells (draw_good: was_seen)
		GoodAsset& a = *g.asset;
		ron::pose_model(*a.model, nullptr, 0, a.posed);
		std::vector<ron::ColorVertex> verts;
		verts.reserve(a.posed.size());
		for (const ron::PosedVertex& p : a.posed) verts.push_back({-3 * p.py, -3 * p.px, 3 * p.pz, -p.ny, -p.nx, p.nz, p.u, p.v, 255, 255, 255, 255});
		const float z = std::max(0.0f, _terrain.sample_height(g.x, g.y));
		const simd_float4x4 at = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0),
		                                     simd_make_float4(g.x, g.y, z, 1));
		rm::DrawUniforms du = rm::draw_uniforms(good_rs, at);
		_states.bind(enc, good_rs, rm::VertexKind::Colored);
		[enc setCullMode:MTLCullModeNone];
		id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
		[enc setVertexBuffer:vb offset:0 atIndex:0];
		[enc setVertexBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentTexture:a.texture atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:a.model->meshes[0].indices.size() indexType:MTLIndexTypeUInt16
		               indexBuffer:a.indices indexBufferOffset:0];
	}
}

- (BuildAsset*)buildAsset:(const std::string&)name {
	auto it = _buildAssets.find(name);
	if (it != _buildAssets.end()) return it->second.get();
	std::unique_ptr<BuildAsset> a;
	if (const ron::BuildGraphic* g = _builds.find(name)) {
		try {
			a = std::make_unique<BuildAsset>();
			a->graphic = g;
			if (!g->texture.empty()) {
				const ron::Image img = ron::parse_tga(ron::read_file(_files->resolve(g->texture)));
				a->sprite_w = img.width;
				a->sprite_h = img.height;
				a->sprite = [self makeTexture:img];
			}
			if (!g->zbuffer.empty()) {
				const ron::BH3Model hull = ron::parse_bh3(ron::read_file(_files->resolve(g->zbuffer)));
				std::vector<ron::PosedVertex> posed;
				ron::pose_model(hull, nullptr, 0, posed);
				for (const ron::PosedVertex& p : posed) a->hull.push_back({-3 * p.py, -3 * p.px, 3 * p.pz, 0, 0, 1, 0, 0, 0, 0, 0, 0});
				a->hull_indices = hull.meshes[0].indices;
			}
			for (const ron::BuildAddon& ev : g->addons) {
				if (ev.anim != ron::BuildAnim::Default) continue;
				const ron::AmmoPiece* piece = _ammo.find(ev.subject);
				if (!piece) continue;
				BuildAsset::Addon ad;
				ad.model = std::make_unique<ron::BH3Model>(ron::parse_bh3(ron::read_file(_files->resolve(piece->model))));
				const std::string clip = ev.anim_file.empty() ? piece->anim : ev.anim_file;
				if (!clip.empty() && !_files->resolve(clip).empty()) {
					ad.anim = std::make_unique<ron::Animation>(ron::parse_bha(ron::read_file(_files->resolve(clip))));
				}
				const std::string tex = piece->texture.empty() ? std::string() : _files->resolve(piece->texture);
				ad.texture = tex.empty() ? _white : [self makeTexture:ron::parse_tga(ron::read_file(tex))];
				ad.state = ron::find_render_state(piece->renderstate);
				if (!ad.state) ad.state = ron::find_render_state("Ammo Blend");
				a->addons.push_back(std::move(ad));
			}
		} catch (const std::exception& e) {
			std::fprintf(stderr, "building %s: %s\n", name.c_str(), e.what());
			a.reset();
		}
	}
	BuildAsset* raw = a.get();
	_buildAssets[name] = std::move(a);
	return raw;
}

// Buildings in painter's order (docs/buildings-spec.md section 7): the sprite with depth off (team-colour pass, then the
// rest), the invisible depth hull, then the add-ons depth-tested against it.
- (void)encodeBuildings:(id<MTLRenderCommandEncoder>)enc {
	static const ron::RenderState& team_rs = *ron::find_render_state("Team Color Blend");
	static const ron::RenderState& build_rs = *ron::find_render_state("Building Blend");
	static const ron::RenderState hull_rs = [] {
		ron::RenderState rs = *ron::find_render_state("Building ZBuffer Blend");
		rs.cull = ron::CullMode::None;  // the hull mapping is a mirror
		return rs;
	}();
	static const ron::RenderState& blocked_rs = *ron::find_render_state("Blocked Building Blend");
	std::vector<ron::PosedVertex> posed;
	// The building being placed (Options::draw_cursor_follows): a ghost drawn with the normal passes when the site is
	// valid, with Blocked Building Blend otherwise; no depth hull or add-ons.
	std::vector<PlacedBuilding> ghost;
	if (_game && _placeType >= 0 && _ghostValid) {
		const int me = _game->local_play;
		const std::string name = [self buildingGraphicForType:_placeType who:me];
		if (BuildAsset* asset = name.empty() ? nullptr : [self buildAsset:name]) {
			ghost.push_back({name, _ghostX, _ghostY, std::clamp(_game->leaders[size_t(me)].color, 0, 8), asset, -2, -1});
		}
	}
	std::vector<const PlacedBuilding*> order;
	for (const PlacedBuilding& b : _placed) order.push_back(&b);
	for (const PlacedBuilding& b : ghost) order.push_back(&b);
	for (const PlacedBuilding* bp : order) {
		const PlacedBuilding& b = *bp;
		const bool is_ghost = b.who == -2;
		// Fog: never-seen buildings are not drawn (BuildData::is_seen; remembered ones stay).
		if (_game && _fogOn && b.who >= 0 && !ron::sim::build_seen_by(*_game, _game->local_play, b.who, b.o)) continue;
		const BuildAsset& a = *b.asset;
		const ron::BuildGraphic& g = *a.graphic;
		const float h = g.halfoffset ? 96.0f : 0.0f;
		const simd_float3 L = simd_make_float3(b.x - h, b.y - h, _terrain.sample_height(b.x, b.y));
		// Construction progress (WallOut::draw): p = hit points / max for unfinished buildings, 0 before the start.
		const ron::sim::BuildView* bv = _game && b.who >= 0 ? [self buildView:b.who o:b.o] : nullptr;
		float p = 1.0f;
		bool unfinished = false;
		if (bv && !bv->active) {
			unfinished = true;
			p = bv->started && bv->max_hit_points > 0 ? float(bv->hit_points) / float(bv->max_hit_points) : 0.0f;
		}
		// The sprite is hidden below 0.84 and fades in over 0.84..0.88; the underlay is the mirror image.
		const int sprite_alpha = !unfinished ? 255 : int(255.0f - 255.0f * std::min(1.0f, std::max(0.0f, 25.0f * (0.88f - p))));
		if (unfinished) {
			[self encodeConstructionOf:b graphic:g type:bv->type at:L alpha:255 - sprite_alpha encoder:enc];
			if (bv->started) [self encodeScaffoldOf:b type:bv->type at:L half:h progress:p encoder:enc];
			if (sprite_alpha <= 0) continue;
		}
		static const uint8_t kBlockedTint[3] = {255, 40, 40};  // the blocked ghost's diffuse (inferred; not decoded)
		const uint8_t* tc = is_ghost && _ghostBlocked != 0 ? kBlockedTint : kBuildTeamColors[b.team];
		if (a.sprite) {
			// One texel covers 3 world units along the camera's right and down axes; texel (spritexoff, spriteyoff) sits on L.
			auto corner = [&, sprite_alpha](float i, float j) {
				const simd_float3 p = L + kRight * (3.0f * (i - float(g.spritexoff))) - kUp * (3.0f * (j - float(g.spriteyoff)));
				return ron::ColorVertex{p.x, p.y, p.z, 0, 0, 1, i / float(a.sprite_w), j / float(a.sprite_h), tc[0], tc[1], tc[2],
				                        uint8_t(sprite_alpha)};
			};
			const float w = float(a.sprite_w), hh = float(a.sprite_h);
			const ron::ColorVertex quad[6] = {corner(0, 0), corner(w, 0), corner(0, hh), corner(0, hh), corner(w, 0), corner(w, hh)};
			const bool blocked = is_ghost && _ghostBlocked != 0;
			const ron::RenderState* passes[2] = {blocked ? &blocked_rs : &team_rs, blocked ? nullptr : &build_rs};
			for (const ron::RenderState* rs : passes) {
				if (!rs) continue;
				rm::DrawUniforms du = rm::draw_uniforms(*rs, matrix_identity_float4x4);
				_states.bind(enc, *rs, rm::VertexKind::Colored);
				[enc setCullMode:MTLCullModeNone];
				[enc setVertexBytes:quad length:sizeof quad atIndex:0];
				[enc setVertexBytes:&du length:sizeof du atIndex:1];
				[enc setFragmentBytes:&du length:sizeof du atIndex:1];
				[enc setFragmentTexture:a.sprite atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
			}
		}
		if (is_ghost) continue;
		const simd_float4x4 at = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0),
		                                     simd_make_float4(L.x, L.y, L.z, 1));
		if (!a.hull_indices.empty()) {
			rm::DrawUniforms du = rm::draw_uniforms(hull_rs, at);
			_states.bind(enc, hull_rs, rm::VertexKind::Colored);
			id<MTLBuffer> vb = [_device newBufferWithBytes:a.hull.data() length:a.hull.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
			id<MTLBuffer> ib = [_device newBufferWithBytes:a.hull_indices.data() length:a.hull_indices.size() * 2 options:MTLResourceStorageModeShared];
			[enc setVertexBuffer:vb offset:0 atIndex:0];
			[enc setVertexBytes:&du length:sizeof du atIndex:1];
			[enc setFragmentBytes:&du length:sizeof du atIndex:1];
			[enc setFragmentTexture:_white atIndex:0];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:a.hull_indices.size() indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
		}
		for (const BuildAsset::Addon& ad : a.addons) {
			const uint32_t t = uint32_t(_timeMs);
			ron::pose_model(*ad.model, ad.anim.get(), t, posed);
			std::vector<ron::ColorVertex> verts;
			verts.reserve(posed.size());
			for (const ron::PosedVertex& p : posed) verts.push_back({-3 * p.py, -3 * p.px, 3 * p.pz, -p.ny, -p.nx, p.nz, p.u, p.v, 255, 255, 255, 255});
			const auto& ix = ad.model->meshes[0].indices;
			if (ix.empty()) continue;
			rm::DrawUniforms du = rm::draw_uniforms(*ad.state, at);
			du.tfactor = simd_make_float4(1, 1, 1, 1);
			_states.bind(enc, *ad.state, rm::VertexKind::Colored);
			[enc setCullMode:MTLCullModeNone];
			id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
			id<MTLBuffer> ib = [_device newBufferWithBytes:ix.data() length:ix.size() * 2 options:MTLResourceStorageModeShared];
			[enc setVertexBuffer:vb offset:0 atIndex:0];
			[enc setVertexBytes:&du length:sizeof du atIndex:1];
			[enc setFragmentBytes:&du length:sizeof du atIndex:1];
			[enc setFragmentTexture:ad.texture atIndex:0];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:ix.size() indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
		}
	}
}

// The construction underlay (WallOut::draw_underlays, get_construct_gpiece): CONSTRUCTION[constructsize - 1], or by the
// building type's size; docks and Senate-type buildings have their own entries (matched by graphic name here: the type
// flags are not in the simulation's rules yet). Drawn like a building sprite.
- (void)encodeConstructionOf:(const PlacedBuilding&)b graphic:(const ron::BuildGraphic&)g type:(int32_t)type at:(simd_float3)L
                      alpha:(int)alpha encoder:(id<MTLRenderCommandEncoder>)enc {
	if (alpha <= 0 || _constructSprites.empty()) return;
	const ron::sim::Type& T = _game->type(type);
	int size = g.constructsize > 0 ? g.constructsize : std::max(T.x_size, T.y_size);
	size_t idx = size_t(std::clamp(size, 1, 8) - 1);
	const std::string low = ron::to_lower(g.name);
	if (low.find("dock") != std::string::npos) idx = 9;
	else if (low.find("senate") != std::string::npos) idx = 10;
	if (idx >= _constructSprites.size()) return;
	const ron::ConstructionSprite& c = _constructSprites[idx];
	if (!_constructTex.count(idx)) {
		id<MTLTexture> t = nil;
		const std::string path = c.texture.empty() ? std::string() : _files->resolve(c.texture);
		if (!path.empty()) {
			const ron::Image img = ron::parse_tga(ron::read_file(path));
			t = [self makeTexture:img];
			_constructW[idx] = img.width, _constructH[idx] = img.height;
		}
		_constructTex[idx] = t;
	}
	id<MTLTexture> tex = _constructTex[idx];
	if (!tex) return;
	const float w = float(_constructW[idx]), hh = float(_constructH[idx]);
	const uint8_t* tc = kBuildTeamColors[b.team];
	auto corner = [&](float i, float j) {
		const simd_float3 q = L + kRight * (3.0f * (i - float(c.spritexoff))) - kUp * (3.0f * (j - float(c.spriteyoff)));
		return ron::ColorVertex{q.x, q.y, q.z, 0, 0, 1, i / w, j / hh, tc[0], tc[1], tc[2], uint8_t(alpha)};
	};
	const ron::ColorVertex quad[6] = {corner(0, 0), corner(w, 0), corner(0, hh), corner(0, hh), corner(w, 0), corner(w, hh)};
	static const ron::RenderState& build_rs = *ron::find_render_state("Building Blend");
	rm::DrawUniforms du = rm::draw_uniforms(build_rs, matrix_identity_float4x4);
	_states.bind(enc, build_rs, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	[enc setVertexBytes:quad length:sizeof quad atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:tex atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Scaffolding (draw_scaffold @907420): SCAFFOLD_TIMING list size - 1 (the last list for Senate-type buildings); each
// piece of the owner's age set (0-2, 3-4, 5+) is drawn while start <= p <= end at coord - 96h + offset, rotated by its
// angle, scale (3, -3, 3). The offset uses the add-ons' building-space mapping (x, y, z) -> (-3y, -3x, 3z).
- (void)encodeScaffoldOf:(const PlacedBuilding&)b type:(int32_t)type at:(simd_float3)L half:(float)h progress:(float)p
                 encoder:(id<MTLRenderCommandEncoder>)enc {
	if (_scaffolds.timings.empty()) return;
	const ron::sim::Type& T = _game->type(type);
	size_t list = size_t(std::clamp(std::max(T.x_size, T.y_size), 1, int(_scaffolds.timings.size()) - 1) - 1);
	if (ron::to_lower(b.name).find("senate") != std::string::npos) list = _scaffolds.timings.size() - 1;
	const int age = _game->leaders[size_t(b.who)].age;
	const int age_set = age <= 2 ? 0 : age <= 4 ? 1 : 2;
	std::vector<ron::PosedVertex> posed;
	for (const ron::ScaffoldTiming& t : _scaffolds.timings[list]) {
		if (p < t.start || p > t.end) continue;
		const ron::ScaffoldPiece* piece = _scaffolds.find(age_set, t.name);
		if (!piece) continue;
		auto it = _scaffoldModels.find(piece);
		if (it == _scaffoldModels.end()) {
			std::unique_ptr<ScaffoldModel> m;
			try {
				if (!piece->model.empty() && !_files->resolve(piece->model).empty()) {
					m = std::make_unique<ScaffoldModel>();
					m->model = std::make_unique<ron::BH3Model>(ron::parse_bh3(ron::read_file(_files->resolve(piece->model))));
					if (!piece->anim_file.empty() && !_files->resolve(piece->anim_file).empty())
						m->anim = std::make_unique<ron::Animation>(ron::parse_bha(ron::read_file(_files->resolve(piece->anim_file))));
					const std::string tp = piece->texture.empty() ? std::string() : _files->resolve(piece->texture);
					m->texture = tp.empty() ? _white : [self makeTexture:ron::parse_tga(ron::read_file(tp))];
					m->state = ron::find_render_state(piece->renderstate);
					if (!m->state) m->state = ron::find_render_state("Ammo Blend");
				}
			} catch (const std::exception& e) {
				std::fprintf(stderr, "scaffold %s: %s\n", piece->name.c_str(), e.what());
				m.reset();
			}
			it = _scaffoldModels.emplace(piece, std::move(m)).first;
		}
		ScaffoldModel* m = it->second.get();
		if (!m || m->model->meshes.empty() || m->model->meshes[0].indices.empty()) continue;
		ron::pose_model(*m->model, m->anim.get(), uint32_t(_timeMs), posed);
		const float a = t.angle * float(M_PI) / 180.0f, ca = std::cos(a), sa = std::sin(a);
		std::vector<ron::ColorVertex> verts;
		verts.reserve(posed.size());
		for (const ron::PosedVertex& v : posed) {
			// Rotate in model space by the piece's angle, then the building-space mapping of the add-ons.
			const float px = v.px * ca - v.py * sa, py = v.px * sa + v.py * ca;
			const float nx = v.nx * ca - v.ny * sa, ny = v.nx * sa + v.ny * ca;
			verts.push_back({-3 * (py + t.y), -3 * (px + t.x), 3 * (v.pz + t.z), -ny, -nx, v.nz, v.u, v.v, 255, 255, 255, 255});
		}
		const simd_float4x4 at = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(0, 0, 1, 0),
		                                     simd_make_float4(L.x, L.y, L.z, 1));
		const auto& ix = m->model->meshes[0].indices;
		rm::DrawUniforms du = rm::draw_uniforms(*m->state, at);
		du.tfactor = simd_make_float4(1, 1, 1, 1);
		_states.bind(enc, *m->state, rm::VertexKind::Colored);
		[enc setCullMode:MTLCullModeNone];
		id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
		id<MTLBuffer> ib = [_device newBufferWithBytes:ix.data() length:ix.size() * 2 options:MTLResourceStorageModeShared];
		[enc setVertexBuffer:vb offset:0 atIndex:0];
		[enc setVertexBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentTexture:m->texture atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:ix.size() indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
	}
	(void)h;
}

- (void)lookAtX:(float)x y:(float)y {
	_lookAt = simd_make_float3(x, y, 0);
}

// World point -> drawable pixel (top-left origin), with the same camera as the renderer.
- (simd_float2)screenOf:(simd_float3)p {
	const CGSize size = [self drawSize];
	const float upp = units_per_pixel(_zoom, float(size.width));
	const simd_float3 d = p - _lookAt;
	return simd_make_float2(float(size.width) / 2 + simd_dot(kRight, d) / upp, float(size.height) / 2 - simd_dot(kUp, d) / upp);
}

- (void)selectAll {
	_selected.clear();
	if (!_game) return;
	for (const ron::sim::UnitView& u : _curView.units) {
		if (u.alive && u.on_map && [self graphicForUnit:u] >= 0) _selected.push_back({u.who, u.o});
	}
}

- (void)selectInRect:(CGRect)r add:(BOOL)add {
	if (!add) _selected.clear();
	const bool click = r.size.width < 4 && r.size.height < 4;
	float best = 40;  // pick radius in pixels for a click
	const SimUnitDrawn* best_u = nullptr;
	auto selected = [&](const SimUnitDrawn& d) {
		return std::find(_selected.begin(), _selected.end(), std::make_pair(d.who, d.o)) != _selected.end();
	};
	for (const SimUnitDrawn& d : _drawnUnits) {
		// Aim at the unit's middle rather than its feet.
		const simd_float3 base = simd_make_float3(d.x, d.y, std::max(0.0f, _terrain.sample_height(d.x, d.y)));
		const simd_float2 sp = [self screenOf:base + simd_make_float3(0, 0, 60)];
		if (click) {
			const float dist = simd_distance(sp, simd_make_float2(float(r.origin.x), float(r.origin.y)));
			if (dist < best) best = dist, best_u = &d;
		} else if (CGRectContainsPoint(r, CGPointMake(sp.x, sp.y)) && !selected(d)) {
			_selected.push_back({d.who, d.o});
		}
	}
	if (click && best_u && !selected(*best_u)) _selected.push_back({best_u->who, best_u->o});
	[self updateTitle];
}

// Selection rings under selected units: a ground ring in the "Circle Blend" state (vertex colour, no depth test).
// The original draws one per guy at a radius from the unit type (UnitOut::draw_unit_circles); one ring per unit for now.
- (void)encodeSelection:(id<MTLRenderCommandEncoder>)enc {
	if (_selected.empty() && _selectedBuilds.empty()) return;
	static const ron::RenderState& circle_rs = *ron::find_render_state("Circle Blend");
	std::vector<ron::ColorVertex> verts;
	std::vector<uint32_t> idx;
	const int kSeg = 24;
	for (const SimUnitDrawn& u : _drawnUnits) {
		if (std::find(_selected.begin(), _selected.end(), std::make_pair(u.who, u.o)) == _selected.end()) continue;
		const float r0 = 70, r1 = 85;
		const uint32_t base = uint32_t(verts.size());
		for (int k = 0; k <= kSeg; k++) {
			const float a = float(k) / kSeg * 2 * float(M_PI), c = std::cos(a), s = std::sin(a);
			for (float r : {r0, r1}) {
				const float x = u.x + c * r, y = u.y + s * r;
				verts.push_back({x, y, std::max(0.0f, _terrain.sample_height(x, y)) + 4, 0, 0, 1, 0, 0, 255, 255, 255, 255});
			}
		}
		for (uint32_t k = 0; k < uint32_t(kSeg); k++) {
			const uint32_t a = base + k * 2;
			idx.insert(idx.end(), {a, a + 1, a + 2, a + 2, a + 1, a + 3});
		}
	}
	// Selected buildings: a ring at the footprint's radius.
	for (const auto& [who, o] : _selectedBuilds) {
		const ron::sim::BuildView* v = [self buildView:who o:o];
		if (!v || !_game) continue;
		const float r0 = float(std::max(_game->type(v->type).x_size, _game->type(v->type).y_size)) * 96.0f + 60, r1 = r0 + 18;
		const uint32_t base = uint32_t(verts.size());
		for (int k = 0; k <= kSeg; k++) {
			const float a = float(k) / kSeg * 2 * float(M_PI), c = std::cos(a), sn = std::sin(a);
			for (float r : {r0, r1}) {
				const float x = float(v->x) + c * r, y = float(v->y) + sn * r;
				verts.push_back({x, y, std::max(0.0f, _terrain.sample_height(x, y)) + 4, 0, 0, 1, 0, 0, 255, 255, 255, 255});
			}
		}
		for (uint32_t k = 0; k < uint32_t(kSeg); k++) {
			const uint32_t a = base + k * 2;
			idx.insert(idx.end(), {a, a + 1, a + 2, a + 2, a + 1, a + 3});
		}
	}
	if (verts.empty()) return;
	rm::DrawUniforms du = rm::draw_uniforms(circle_rs, matrix_identity_float4x4);
	// Drawn after tone mapping (ObjectsOut::draw_overlays, lighting-spec step 10), so Circle Blend's plain vertex colour
	// shows at full brightness (lighting-spec open question 2).
	_overlayStates.bind(enc, circle_rs, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	id<MTLBuffer> ib = [_device newBufferWithBytes:idx.data() length:idx.size() * 4 options:MTLResourceStorageModeShared];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_white atIndex:0];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:idx.size() indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0];
}

- (void)scrollByPixelsX:(float)dx y:(float)dy {
	// Screen right = kRight, screen up = the ground projection of kUp. Clamp to the map, as the game does.
	const CGSize size = [self drawSize];
	const float upp = units_per_pixel(_zoom, float(size.width));
	const simd_float3 ground_up = simd_normalize(simd_make_float3(kUp.x, kUp.y, 0)) / 0.5f;  // 1 px up = 2 ground units/upp
	_lookAt += (kRight * dx + ground_up * dy) * upp;
	_lookAt.x = std::clamp(_lookAt.x, 0.0f, _mesh.width);
	_lookAt.y = std::clamp(_lookAt.y, 0.0f, _mesh.height);
}

- (void)handleKey:(NSEvent*)event {
	if (_gameMenu) {
		[self gameMenuKey:event];
		return;
	}
	if (event.keyCode == 109 && !_inPopup) {  // F10: the game menu
		[self openGameMenu:1];
		return;
	}
	if ([self handleGroupKey:event]) {
		[self updateTitle];
		return;
	}
	if (_inPopup) {  // BasePop: Return takes the first (accept) button; other keys wait for a click
		if (event.keyCode == 36 || event.keyCode == 76) _popupResult = 0;
		return;
	}
	if (_sviewOn && _sview.goal_dialog_open() && (event.keyCode == 53 || event.keyCode == 36)) {  // Esc / Return close
		_sview.close_goal_dialog();
		return;
	}
	const ron::sim::ScriptPresentation* sp = [self pres];
	const bool scroll_locked = sp && (sp->scroll_lock_flags & 1), zoom_locked = sp && (sp->zoom_lock_flags & 1);
	if (event.keyCode == 53 && (_placeType >= 0 || _targeting >= 0 || _buildPage >= 0)) {  // Escape: cancel the mode
		_placeType = -1, _targeting = -1, _buildPage = -1;
		return;
	}
	NSString* chars = event.charactersIgnoringModifiers;
	const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
	const float step = 120;
	switch (c) {
		case NSRightArrowFunctionKey: if (!scroll_locked) [self scrollByPixelsX:step y:0]; break;
		case NSLeftArrowFunctionKey: if (!scroll_locked) [self scrollByPixelsX:-step y:0]; break;
		case NSUpArrowFunctionKey: if (!scroll_locked) [self scrollByPixelsX:0 y:step]; break;
		case NSDownArrowFunctionKey: if (!scroll_locked) [self scrollByPixelsX:0 y:-step]; break;
		case '+': case '=': if (!zoom_locked) _zoom = std::min(_zoom + 1, 6); break;
		case '-': case '_': if (!zoom_locked) _zoom = std::max(_zoom - 1, 0); break;
		case 'b': case 'B': _bloom = !_bloom; break;
		case 27:  // Escape: clear the selection, else the game menu
			if (_selected.empty() && _selectedBuilds.empty() && !(_sviewOn && _sview.modal())) [self openGameMenu:1];
			_selected.clear(), _selectedBuilds.clear();
			break;
		case 'h': case 'H': _hudOn = !_hudOn; break;
		case 'p': case 'P':
			if (!(sp && sp->pause_disabled)) _paused = !_paused;  // pause_disable
			break;
		case 'f': case 'F': _fogOn = !_fogOn; break;
		default: break;
	}
	[self updateTitle];
}

- (void)updateTitle {
	self.view.window.title = [NSString stringWithFormat:@"%s  —  zoom %d  (%.0f, %.0f)%@", _title.c_str(), _zoom,
	                                                    _lookAt.x, _lookAt.y, _bloom ? @"  [bloom]" : @""];
	if (!_selected.empty()) self.view.window.title = [self.view.window.title stringByAppendingFormat:@"  —  %zu selected", _selected.size()];
	if (_game) self.view.window.title = [self.view.window.title stringByAppendingFormat:@"  —  frame %d%@", _game->frame, _paused ? @" (paused)" : @""];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
}

- (void)renderInto:(id<MTLTexture>)output commandBuffer:(id<MTLCommandBuffer>)cb {
	const NSUInteger w = output.width, h = output.height;
	_drawW = CGFloat(w), _drawH = CGFloat(h);
	_targets.ensure(_device, w, h);
	[self buildFigures];
	[self updateFog];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:_targets.scene_pass(MTLClearColorMake(0.02, 0.05, 0.12, 1))];

	rm::SceneUniforms scene{};
	camera_matrices(_lookAt, units_per_pixel(_zoom, float(w)), float(w), float(h), scene.view, scene.proj);
	scene.light_dir = simd_make_float4(ron::kSunDir[0], ron::kSunDir[1], ron::kSunDir[2], 0);
	scene.ambient_light = simd_make_float4(_lighting.ambient_light[0], _lighting.ambient_light[1], _lighting.ambient_light[2], 1);
	// Terrain pass: the Sun carries the tileset's diffuse light (prep_terrain_lighting).
	scene.light_diffuse = simd_make_float4(_terrainLight[0], _terrainLight[1], _terrainLight[2], 1);
	[enc setVertexBytes:&scene length:sizeof scene atIndex:2];
	[enc setFragmentBytes:&scene length:sizeof scene atIndex:2];

	// The camera basis is mirrored relative to a right-handed view (the original's world is left-handed). Together with
	// the terrain's index order, CULL CCW then removes back faces exactly as in the original: no flip needed.
	const bool flip = false;
	// Ocean floor sheet: covers the faded-out shelf and deep land under the sea. The original draws it right after the
	// land, where faded land (still writing depth) between z = -52 and -101 would show the black clear colour as a dark
	// rim along every coast (docs/water-spec.md 2.5, unconfirmed). Drawing it first lets that land fade over the floor
	// instead; revisit once compared with an in-game screenshot.
	if (_floorVB && !debug_skip("floor")) {
		static const ron::RenderState floor_rs = floor_state();
		rm::DrawUniforms fu = rm::draw_uniforms(floor_rs, matrix_identity_float4x4);
		_states.bind(enc, floor_rs, rm::VertexKind::Colored2, false, flip);
		[enc setVertexBuffer:_floorVB offset:0 atIndex:0];
		[enc setVertexBytes:&fu length:sizeof fu atIndex:1];
		[enc setFragmentBytes:&fu length:sizeof fu atIndex:1];
		[enc setFragmentTexture:_floorTex atIndex:0];
		[enc setFragmentTexture:_floorTex atIndex:1];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_mesh.floor_indices.size() indexType:MTLIndexTypeUInt32 indexBuffer:_floorIB indexBufferOffset:0];
	}
	rm::DrawUniforms du = rm::draw_uniforms(_landState, matrix_identity_float4x4);
	_states.bind(enc, _landState, rm::VertexKind::Colored, false, flip);
	[enc setVertexBuffer:_landVB offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	for (size_t i = 0; i < _bucketIB.size() && !debug_skip("land"); i++) {
		[enc setFragmentTexture:_bucketTex[i] atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_mesh.buckets[i].indices.size() indexType:MTLIndexTypeUInt32
		               indexBuffer:_bucketIB[i] indexBufferOffset:0];
	}
	// Transitions (after land, before objects): ground texture on stage 0, mask on stage 1 with UV1.
	static const ron::RenderState trans_rs = transition_state(), sandy_rs = coral_state(false), coral_rs = coral_state(true);
	for (const TransitionDraw& t : _transitions) {
		// Ocean overlays (CoralSandy + CoralTrans, no depth test) come out as hard turquoise bands over deep water rather
		// than the faint fringe the spec expects (docs/water-spec.md 2.6), so they are off unless RON_CORAL=1.
		if (t.ocean && !getenv("RON_CORAL")) continue;
		if (debug_skip(t.ocean ? "coral" : "trans")) continue;
		const int passes = t.ocean && _coral ? 2 : 1;
		for (int pass = 0; pass < passes; pass++) {
			const ron::RenderState& rs = !t.ocean ? trans_rs : pass == 0 ? sandy_rs : coral_rs;
			rm::DrawUniforms tu = rm::draw_uniforms(rs, matrix_identity_float4x4);
			_states.bind(enc, rs, rm::VertexKind::Colored2, false, flip);
			[enc setVertexBuffer:t.vb offset:0 atIndex:0];
			[enc setVertexBytes:&tu length:sizeof tu atIndex:1];
			[enc setFragmentBytes:&tu length:sizeof tu atIndex:1];
			[enc setFragmentTexture:(pass == 0 ? t.texture : _coral) atIndex:0];
			[enc setFragmentTexture:t.mask atIndex:1];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:t.count indexType:MTLIndexTypeUInt32 indexBuffer:t.ib indexBufferOffset:0];
		}
	}
	// River troughs, mountains (two draws per range), snowcaps, then doobers (terrain-dressing-spec section 6).
	static const ron::RenderState mtn_rs = mountain_state(), snow_rs = snowcap_state(), trough_rs = trough_state();
	auto draw_mesh = [&](const ron::RenderState& rs, rm::VertexKind kind, const MeshDraw& m, id<MTLTexture> t0, id<MTLTexture> t1) {
		rm::DrawUniforms du = rm::draw_uniforms(rs, matrix_identity_float4x4);
		_states.bind(enc, rs, kind, false, flip);
		[enc setVertexBuffer:m.vb offset:0 atIndex:0];
		[enc setVertexBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentBytes:&du length:sizeof du atIndex:1];
		[enc setFragmentTexture:t0 atIndex:0];
		[enc setFragmentTexture:(t1 ?: t0) atIndex:1];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:m.count indexType:MTLIndexTypeUInt32 indexBuffer:m.ib indexBufferOffset:0];
	};
	// Farm ground (render_weathering(0, 3): the pigfarm and wheatfarm underlays), before roads and river troughs.
	for (int k = 1; k >= 0; k--) {
		if (_farmUnderlays[k].vb) draw_mesh(snow_rs, rm::VertexKind::Colored2, _farmUnderlays[k], _farmUnderlays[k].tex0, _farmUnderlays[k].tex1);
	}
	for (const MeshDraw& m : _troughDraws) draw_mesh(trough_rs, rm::VertexKind::Colored, m, m.tex0, nil);
	for (const MeshDraw& m : _mountainDraws) {
		draw_mesh(mtn_rs, rm::VertexKind::Colored2, m, m.tex0, m.tex1);
		draw_mesh(mtn_rs, rm::VertexKind::Colored2, m, m.tex0b, m.tex1b);
	}
	if (_snowcapDraw.vb) draw_mesh(snow_rs, rm::VertexKind::Colored2, _snowcapDraw, _snowcapDraw.tex0, _snowcapDraw.tex1);
	// Object pass onward (objects, water): the Sun at full white (prep_unit_lighting).
	scene.light_diffuse = simd_make_float4(1, 1, 1, 1);
	[enc setVertexBytes:&scene length:sizeof scene atIndex:2];
	[enc setFragmentBytes:&scene length:sizeof scene atIndex:2];
	static const ron::RenderState& doober_rs = *ron::find_render_state("Doober Blend");
	for (const MeshDraw& m : _dooberDraws) draw_mesh(doober_rs, rm::VertexKind::Colored, m, m.tex0, nil);
	scene.light_diffuse = simd_make_float4(1, 1, 1, 1);
	[enc setVertexBytes:&scene length:sizeof scene atIndex:2];
	[enc setFragmentBytes:&scene length:sizeof scene atIndex:2];
	[self encodeFootprint:enc];
	[self encodeBuildings:enc];
	[self encodeGoods:enc];
	[self encodeUnits:enc];
	if (_treeVB) {
		rm::DrawUniforms tu = rm::draw_uniforms(_treeState, matrix_identity_float4x4);
		tu.diffuse = simd_make_float4(0.5f, 0.5f, 0.5f, 1);
		_states.bind(enc, _treeState, rm::VertexKind::Colored, false, flip);
		[enc setVertexBuffer:_treeVB offset:0 atIndex:0];
		[enc setVertexBytes:&tu length:sizeof tu atIndex:1];
		[enc setFragmentBytes:&tu length:sizeof tu atIndex:1];
		for (int i = 0; i < ron::kTreeSlots; i++) {
			if (!_treeIB[i]) continue;
			[enc setFragmentTexture:_treeTex[i] atIndex:0];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_treeCount[i] indexType:MTLIndexTypeUInt32
			               indexBuffer:_treeIB[i] indexBufferOffset:0];
		}
	}
	[self encodeWheat:enc];
	if (_waterIB && !debug_skip("water")) {
		rm::DrawUniforms wu = rm::draw_uniforms(_waterState, matrix_identity_float4x4);
		wu.mat_ambient = simd_make_float4(0.2f, 0.2f, 0.2f, 1);  // the water material (TerrainOut::one_time_init)
		wu.mat_diffuse = simd_make_float4(1, 1, 1.5f, 1);
		_states.bind(enc, _waterState, rm::VertexKind::Colored, false, flip);
		[enc setVertexBuffer:_waterVB offset:0 atIndex:0];
		[enc setVertexBytes:&wu length:sizeof wu atIndex:1];
		[enc setFragmentBytes:&wu length:sizeof wu atIndex:1];
		[enc setFragmentTexture:_white atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_mesh.water_indices.size() indexType:MTLIndexTypeUInt32
		               indexBuffer:_waterIB indexBufferOffset:0];
	}
	if (_riverWaterDraw.vb) {  // the faint river sheen, after the sea water
		static const ron::RenderState river_rs = river_water_state();
		draw_mesh(river_rs, rm::VertexKind::Colored2, _riverWaterDraw, _riverWaterDraw.tex0, _riverWaterDraw.tex1);
	}
	// Fog of war last, so it also covers water (the original draws it before objects and water, terrain-spec B6).
	[self encodeFog:enc];
	[enc endEncoding];

	_post.encode(cb, _targets.hdr(), output, rm::tonemap_params(ron::ToneMapSettings{}), _bloom);

	// Post-tonemap overlays (Scene::render step 10): selection circles and health bars.
	id<MTLRenderCommandEncoder> oe = [cb renderCommandEncoderWithDescriptor:rm::overlay_pass(output)];
	[oe setVertexBytes:&scene length:sizeof scene atIndex:2];
	[oe setFragmentBytes:&scene length:sizeof scene atIndex:2];
	[self encodeSelection:oe];
	[self encodeAnnounce:oe];
	[self encodeHealthBars:oe];
	// The interface (Window::update_screen + IFaceRenderManager::flush_all + FontFamily::flush_fonts), after the overlays.
	[self encodeHud:oe width:w height:h];
	[oe endEncoding];
}

- (void)drawInMTKView:(MTKView*)view {
	const double now = CACurrentMediaTime(), before = _timeMs;
	if (_lastFrame > 0) _timeMs += std::min(0.1, now - _lastFrame) * 1000.0;
	_lastFrame = now;
	[self advanceFarmsTo:_farmFrame + uint32_t(_timeMs * 0.015) - uint32_t(before * 0.015)];  // 15 simulation frames a second
	const bool modal = _inPopup || (_sviewOn && _sview.goal_dialog_open()) || _gameMenu != 0;
	// The game is over for the local player: after the notice has played, offer the way back (ENDGAMEWIN's role).
	if (_sviewOn && _sview.game_is_over() && !_overOffered) {
		if (_overMs < 0) _overMs = _timeMs;
		if (_timeMs - _overMs > 5000 && !_inPopup && !_gameMenu) {
			_overOffered = YES;
			[self openGameMenu:2];
		}
	}
	if (_game && !_paused && !modal) {
		_simMs += _timeMs - before;
		int steps = int(_simMs / kSimFrameMs);
		if (steps > 4) {  // fell behind (a stall): drop the backlog rather than fast-forwarding
			_simMs = std::fmod(_simMs, kSimFrameMs);
			steps = 4;
		} else {
			_simMs -= steps * kSimFrameMs;
		}
		[self stepSimulation:steps];
		if (steps && (_game->frame % 15) == 0) [self updateTitle];
	}
	_uiScale = view.window ? float(view.window.backingScaleFactor) : 1.0f;
	if (!_inPopup) [self cameraStep:_timeMs - before];
	if (_audio) _audio->update(_timeMs);
	[self edgeScroll:_timeMs - before];
	id<CAMetalDrawable> drawable = view.currentDrawable;
	if (!drawable) return;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	[self renderInto:drawable.texture commandBuffer:cb];
	[cb presentDrawable:drawable];
	[cb commit];
}

// Unattended farm growth, one Farms::inc_time per simulation frame (15 per second).
- (void)advanceFarmsTo:(uint32_t)frame {
	if (_game) return;  // the simulation grows its farms (Farms::inc_time); syncSimFarms copies the state
	for (; _farmFrame < frame; _farmFrame++) ron::farms_inc_time(_farms, _farmSeed);
}

- (BOOL)snapshotTo:(NSString*)path width:(int)w height:(int)h scale:(float)scale {
	id<MTLTexture> out = rm::make_readback_target(_device, w, h);
	_uiScale = scale > 0 ? scale : 1;  // UI pixels drawn at `scale` snapshot pixels (1: the original's screen pixels)
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	[self renderInto:out commandBuffer:cb];
	[cb commit];
	[cb waitUntilCompleted];
	if (!rm::write_png(out, path.UTF8String)) {
		std::fprintf(stderr, "could not write %s\n", path.UTF8String);
		return NO;
	}
	std::printf("wrote %s (%dx%d, zoom %d)\n", path.UTF8String, w, h, _zoom);
	return YES;
}

// ---------------------------------------------------------------- interface (docs/ui-port.md)

// The drawable size of the frame being rendered (the window's drawable, or the snapshot target).
- (CGSize)drawSize {
	if (_drawW > 0 && _drawH > 0) return CGSizeMake(_drawW, _drawH);
	return self.view.drawableSize;
}

// WorldMapBackground::render @008cfc40: the map drawn once, top-down (yaw 0, ortho over [0,W] x [0,H]), into a 256 x 256
// texture: terrain and water, then the trees as flat tree_minimap_color (0x425542) squares. Rivers, mountain tints and
// the ocean gradient quad are not drawn yet.
- (void)renderMinimapBackground {
	if (!_hudOn || _bucketIB.empty()) return;
	const NSUInteger S = 256;
	MTLTextureDescriptor* cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:S height:S mipmapped:NO];
	cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	cd.storageMode = MTLStorageModePrivate;
	_miniBG = [_device newTextureWithDescriptor:cd];
	MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:S height:S mipmapped:NO];
	dd.usage = MTLTextureUsageRenderTarget;
	dd.storageMode = MTLStorageModePrivate;
	id<MTLTexture> depth = [_device newTextureWithDescriptor:dd];
	rm::StateCache cache;
	std::string err;
	if (!cache.init(_device, MTLPixelFormatBGRA8Unorm, MTLPixelFormatDepth32Float, err)) return;
	MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = _miniBG;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	rp.depthAttachment.texture = depth;
	rp.depthAttachment.loadAction = MTLLoadActionClear;
	rp.depthAttachment.storeAction = MTLStoreActionDontCare;
	rp.depthAttachment.clearDepth = 1;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	rm::SceneUniforms scene{};
	scene.view = matrix_identity_float4x4;
	const float W = _mesh.width, H = _mesh.height;
	scene.proj = simd_matrix(simd_make_float4(2 / W, 0, 0, 0), simd_make_float4(0, -2 / H, 0, 0), simd_make_float4(0, 0, -1.0f / 20000, 0),
	                         simd_make_float4(-1, 1, 0.5f, 1));
	scene.light_dir = simd_make_float4(ron::kSunDir[0], ron::kSunDir[1], ron::kSunDir[2], 0);
	scene.ambient_light = simd_make_float4(_lighting.ambient_light[0], _lighting.ambient_light[1], _lighting.ambient_light[2], 1);
	scene.light_diffuse = simd_make_float4(_terrainLight[0], _terrainLight[1], _terrainLight[2], 1);
	[enc setVertexBytes:&scene length:sizeof scene atIndex:2];
	[enc setFragmentBytes:&scene length:sizeof scene atIndex:2];
	rm::DrawUniforms du = rm::draw_uniforms(_landState, matrix_identity_float4x4);
	cache.bind(enc, _landState, rm::VertexKind::Colored, true);
	[enc setCullMode:MTLCullModeNone];
	[enc setVertexBuffer:_landVB offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	for (size_t i = 0; i < _bucketIB.size(); i++) {
		[enc setFragmentTexture:_bucketTex[i] atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_mesh.buckets[i].indices.size() indexType:MTLIndexTypeUInt32
		               indexBuffer:_bucketIB[i] indexBufferOffset:0];
	}
	if (_waterIB) {
		rm::DrawUniforms wu = rm::draw_uniforms(_waterState, matrix_identity_float4x4);
		wu.mat_ambient = simd_make_float4(0.2f, 0.2f, 0.2f, 1);
		wu.mat_diffuse = simd_make_float4(1, 1, 1.5f, 1);
		cache.bind(enc, _waterState, rm::VertexKind::Colored, true);
		[enc setCullMode:MTLCullModeNone];
		[enc setVertexBuffer:_waterVB offset:0 atIndex:0];
		[enc setVertexBytes:&wu length:sizeof wu atIndex:1];
		[enc setFragmentBytes:&wu length:sizeof wu atIndex:1];
		[enc setFragmentTexture:_white atIndex:0];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_mesh.water_indices.size() indexType:MTLIndexTypeUInt32
		               indexBuffer:_waterIB indexBufferOffset:0];
	}
	if (!_treeXY.empty()) {
		ron::RenderState rs = *ron::find_render_state("Circle Blend");
		rs.enables = 0;  // opaque, no depth test
		std::vector<ron::ColorVertex> v;
		const float r = std::max(W, H) / 256.0f * 0.75f;
		for (const simd_float2& t : _treeXY) {
			auto p = [&](float dx, float dy) { return ron::ColorVertex{t.x + dx, t.y + dy, 5000, 0, 0, 1, 0, 0, 0x42, 0x55, 0x42, 255}; };
			const ron::ColorVertex q[6] = {p(-r, -r), p(r, -r), p(-r, r), p(-r, r), p(r, -r), p(r, r)};
			v.insert(v.end(), q, q + 6);
		}
		rm::DrawUniforms tu = rm::draw_uniforms(rs, matrix_identity_float4x4);
		cache.bind(enc, rs, rm::VertexKind::Colored, true);
		[enc setCullMode:MTLCullModeNone];
		id<MTLBuffer> vb = [_device newBufferWithBytes:v.data() length:v.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
		[enc setVertexBuffer:vb offset:0 atIndex:0];
		[enc setVertexBytes:&tu length:sizeof tu atIndex:1];
		[enc setFragmentBytes:&tu length:sizeof tu atIndex:1];
		[enc setFragmentTexture:_white atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:v.size()];
	}
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	_ui.set_texture("MINIMAP_BG", _miniBG, int(S), int(S));
}

// WorldMapFog::fill_colors_fog @8d1420: luminance 0xff (visible), 0x80 (seen), 0x50 (explored), 0 (unexplored).
- (void)updateMinimapFog {
	if (!_fogUploaded || _fogLevels.empty() || _fog.fxs <= 0) return;
	if (_miniFog && _miniFogLevels == _fogLevels) return;
	_miniFogLevels = _fogLevels;
	if (!_miniFog) {
		MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                                             width:NSUInteger(_fog.fxs)
		                                                                            height:NSUInteger(_fog.fys)
		                                                                         mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead;
		_miniFog = [_device newTextureWithDescriptor:d];
		_ui.set_texture("MINIMAP_FOG", _miniFog, _fog.fxs, _fog.fys);
	}
	static const uint8_t lum[4] = {0, 0x50, 0x80, 0xff};
	std::vector<uint8_t> rgba(_miniFogLevels.size() * 4);
	for (size_t i = 0; i < _miniFogLevels.size(); i++) {
		const uint8_t l = lum[std::min<uint8_t>(_miniFogLevels[i], 3)];
		rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = l;
		rgba[i * 4 + 3] = 255;
	}
	[_miniFog replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(_fog.fxs), NSUInteger(_fog.fys)) mipmapLevel:0 withBytes:rgba.data()
	            bytesPerRow:NSUInteger(_fog.fxs) * 4];
}

// The building_graphics.xml graphic of a building type for leader `who` (nation build style, age), as the scenario
// resolver picks it; "" for farms and graphics without a sprite.
- (std::string)buildingGraphicForType:(int32_t)type who:(int32_t)who {
	if (!_game || !_simRules || who < 0 || who >= int32_t(_game->leaders.size())) return std::string();
	const std::string graph = ron::sim::to_utf8(_game->type(type).graph_name);
	if (graph.empty() || graph == "FARM") return std::string();
	const ron::sim::Leader& L = _game->leaders[size_t(who)];
	int bc = 0, backup = 0;
	if (L.tribe >= 0 && size_t(L.tribe) < _simRules->tribes.size()) {
		bc = _simRules->tribes[size_t(L.tribe)].build_continent;
		backup = _simRules->tribes[size_t(L.tribe)].backup_build_continent;
	}
	const ron::BuildGraphic* g = _builds.find_variant(graph, ron::build_style_name(bc), L.age, ron::build_style_name(backup));
	return g && !g->texture.empty() ? g->name : std::string();
}

// Buildings follow the simulation: sites placed in play appear, destroyed ones disappear. Scenario buildings keep the
// graphic the scenario resolver gave them while their (who, o) is alive.
- (void)syncSimBuildings {
	if (!_game) return;
	std::set<std::pair<int32_t, int32_t>> alive;
	for (const ron::sim::BuildView& b : _curView.builds) {
		if (b.alive) alive.insert({b.who, b.o});
	}
	_placed.erase(std::remove_if(_placed.begin(), _placed.end(),
	                             [&](const PlacedBuilding& p) { return p.who >= 0 && !alive.count({p.who, p.o}); }),
	              _placed.end());
	std::set<std::pair<int32_t, int32_t>> have;
	for (const PlacedBuilding& p : _placed) {
		if (p.who >= 0) have.insert({p.who, p.o});
	}
	for (const ron::sim::BuildView& b : _curView.builds) {
		if (!b.alive || have.count({b.who, b.o})) continue;
		const std::string g = [self buildingGraphicForType:b.type who:b.who];
		if (g.empty() || ![self placeBuilding:g x:float(b.x) y:float(b.y) team:b.color]) continue;
		for (PlacedBuilding& p : _placed) {
			if (p.who < 0 && p.x == float(b.x) && p.y == float(b.y) && p.name == g) {
				p.who = b.who, p.o = b.o;
				break;
			}
		}
	}
	// Selected buildings that no longer exist leave the selection.
	_selectedBuilds.erase(std::remove_if(_selectedBuilds.begin(), _selectedBuilds.end(), [&](const auto& k) { return !alive.count(k); }),
	                      _selectedBuilds.end());
}

- (const ron::sim::UnitView*)unitView:(int32_t)who o:(int32_t)o {
	for (const ron::sim::UnitView& u : _curView.units) {
		if (u.who == who && u.o == o) return &u;
	}
	return nullptr;
}

- (const ron::sim::BuildView*)buildView:(int32_t)who o:(int32_t)o {
	for (const ron::sim::BuildView& b : _curView.builds) {
		if (b.who == who && b.o == o) return &b;
	}
	return nullptr;
}

- (std::string)typeName:(int32_t)t {
	const ron::sim::Type& T = _game->type(t);
	std::string n = ron::sim::to_utf8(T.display_name);
	if (n.empty()) n = ron::sim::to_utf8(T.name);
	return n;
}

// The interface icon of a unit type for an owner: its graphic's tex_id / tex_col / tex_row.
- (void)unitIcon:(int32_t)type who:(int32_t)who o:(int32_t)o into:(std::string&)tex col:(int&)col row:(int&)row x:(int&)tx y:(int&)ty {
	ron::sim::UnitView u;
	u.who = who, u.o = o, u.type = type;
	const int g = [self graphicForUnit:u];
	if (g < 0) return;
	const ron::UnitGraphic& ug = _units.units()[size_t(g)];
	tex = ug.tex_id, col = ug.tex_col, row = ug.tex_row, tx = ug.tex_x, ty = ug.tex_y;
}

- (int)localPlayer {
	return _game ? _game->local_play : 0;
}

// The command card (Options, docs/ui-spec.md 6.4): unit orders (UnitOut::make_options), the build menu pages
// (BUILD_OPTIONS: building types the leader can build, type_avail == 4, by GRID_X / GRID_Y and page = cat), or a
// building's train / research buttons (BuildData::can_make: 4 train, 2 research; units at (GRID_X, GRID_Y), their
// upgrades one row down, techs and building upgrades at their own slots).
- (std::vector<hud::Option>)hudOptions {
	std::vector<hud::Option> out;
	if (!_game) return out;
	const int me = [self localPlayer];
	auto opt = [&](int option, int gx, int gy, bool enabled) {
		hud::Option o;
		o.option = option, o.grid_x = gx, o.grid_y = gy, o.enabled = enabled, o.latched = _targeting == option;
		out.push_back(o);
		return &out.back();
	};
	if (!_selected.empty()) {
		bool own = true, citizens = false;
		for (const auto& [who, o] : _selected) {
			own = own && who == me;
			if (const ron::sim::UnitView* u = [self unitView:who o:o]) {
				citizens = citizens || u->type == ron::sim::ptype::kPeasants || u->type == ron::sim::ptype::kPeasantsKorean;
			}
		}
		if (_placeType >= 0 || _targeting >= 0) {
			opt(hud::kOptCancel, 4, 3, true);
			return out;
		}
		if (_buildPage >= 0 && citizens && own) {
			for (int32_t t = 414; t < 543; t++) {
				const ron::sim::Type& T = _game->type(t);
				if (!T.loaded || T.cat != _buildPage) continue;
				if (ron::sim::type_avail(*_game, me, t, 1) != 4) continue;
				hud::Option* o = opt(1000, T.grid_x, T.grid_y, ron::sim::can_pay_cost(*_game, t, me, -1, -1, 1) > 0);
				o->object = t;
				o->tex_id = ron::sim::to_utf8(T.tex.id), o->tex_col = T.tex.col, o->tex_row = T.tex.row;
				o->tex_x = T.tex.x > 0 ? T.tex.x : -1, o->tex_y = T.tex.y > 0 ? T.tex.y : -1;
			}
			opt(66, 2, 3, true);  // BACK
			opt(65, 3, 3, true);  // NEXT
			opt(hud::kOptCancel, 4, 3, true);
			return out;
		}
		opt(hud::kOptMoveTo, 0, 0, own);
		opt(hud::kOptAttackTo, 1, 0, false);  // TODO(sim): the ATTACK_TO verb (attack-move) is not ported
		if (citizens) {
			opt(hud::kOptBuild, 0, 1, own);
			opt(hud::kOptBuildMilitary, 1, 1, own);
			opt(hud::kOptBuildWonder, 2, 1, own);
			opt(hud::kOptRepair, 3, 1, false);
			opt(hud::kOptAlarmPeasant, 4, 0, false);
		}
		opt(hud::kOptHalt, 0, 3, own);
		opt(hud::kOptGarrison, 1, 3, false);
		return out;
	}
	if (!_selectedBuilds.empty()) {
		const auto [who, o] = _selectedBuilds.front();
		const ron::sim::Build* b = _game->build(who, o);
		if (!b) return out;
		const bool own = who == me;
		for (int32_t t = 50; t < 629; t++) {
			if (!_game->type(t).loaded) continue;
			const int32_t a = ron::sim::build_can_make(*_game, *b, t, 1);
			if (a == 0) continue;
			const ron::sim::Type& T = _game->type(t);
			const bool unit = ron::sim::is_unit_type(t);
			hud::Option* op = opt(unit && a >= 4 ? hud::kOptTrain : hud::kOptResearch, T.grid_x, T.grid_y + (unit && a < 4 ? 1 : 0),
			                      own && ron::sim::can_pay_cost(*_game, t, who, -1, o, 1) > 0);
			op->object = t;
			if (unit) {
				[self unitIcon:t who:who o:-1 into:op->tex_id col:op->tex_col row:op->tex_row x:op->tex_x y:op->tex_y];
			} else {
				op->tex_id = ron::sim::to_utf8(T.tex.id), op->tex_col = T.tex.col, op->tex_row = T.tex.row;
				op->tex_x = T.tex.x > 0 ? T.tex.x : -1, op->tex_y = T.tex.y > 0 ? T.tex.y : -1;
			}
		}
	}
	return out;
}

- (hud::State)makeHudState {
	hud::State s;
	s.world_w = std::max(1.0f, _mesh.width);
	s.world_h = std::max(1.0f, _mesh.height);
	if (_fogOn && _miniFog && !_miniFogLevels.empty()) {
		s.fog = &_miniFogLevels;
		s.fog_xs = _fog.fxs, s.fog_ys = _fog.fys;
	}
	s.has_minimap_bg = _miniBG != nil;
	const int me = [self localPlayer];
	if (_game) {
		for (const ron::sim::UnitView& u : _curView.units) {
			if (!u.alive || !u.on_map) continue;
			if (_fogOn && !(u.seen_by & (1u << (me & 7)))) continue;
			hud::Blip b;
			b.x = float(u.x), b.y = float(u.y);
			const uint8_t* tc = kUnitTeamColors[std::clamp(u.color, 0, 8)];
			b.rgb[0] = tc[0], b.rgb[1] = tc[1], b.rgb[2] = tc[2];
			b.size = u.type >= 50 && u.type <= 53 ? 1 : 2;  // citizens and scholars size 1
			s.blips.push_back(b);
		}
		for (const ron::sim::BuildView& v : _curView.builds) {
			if (!v.alive) continue;
			if (_fogOn && !(v.seen_by & (1u << (me & 7)))) continue;
			hud::Blip b;
			b.x = float(v.x), b.y = float(v.y), b.building = true;
			const uint8_t* tc = kUnitTeamColors[std::clamp(v.color, 0, 8)];
			b.rgb[0] = tc[0], b.rgb[1] = tc[1], b.rgb[2] = tc[2];
			b.size = v.city ? 6 : 3;
			s.blips.push_back(b);
		}
	}
	const CGSize size = [self drawSize];
	const simd_float2 a = [self groundAt:CGPointMake(0, 0)], b = [self groundAt:CGPointMake(size.width, size.height)];
	s.view_corners[0] = a.x, s.view_corners[1] = a.y, s.view_corners[2] = b.x, s.view_corners[3] = b.y;
	for (const auto& [who, o] : _selected) {
		const ron::sim::UnitView* u = [self unitView:who o:o];
		if (!u) continue;
		hud::Object ob;
		ob.who = who, ob.o = o, ob.type = u->type, ob.hp = u->hit_points, ob.max_hp = u->max_hit_points, ob.own = who == me;
		const uint8_t* tc = kUnitTeamColors[std::clamp(u->color, 0, 8)];
		ob.rgb[0] = tc[0], ob.rgb[1] = tc[1], ob.rgb[2] = tc[2];
		ob.name = [self typeName:u->type];
		[self unitIcon:u->type who:who o:o into:ob.tex_id col:ob.tex_col row:ob.tex_row x:ob.tex_x y:ob.tex_y];
		const ron::sim::Type& T = _game->type(u->type);
		ob.attack = T.attack > 0 ? T.attack / 10 : -1;  // draw_stat: base / 10 (+ bonus / 10, no bonuses yet)
		ob.armor = T.armor > 0 ? T.armor : -1;
		ob.range = T.max_range > 0 ? T.max_range : -1;
		s.selection.push_back(ob);
	}
	for (const auto& [who, o] : _selectedBuilds) {
		const ron::sim::BuildView* v = [self buildView:who o:o];
		if (!v) continue;
		hud::Object ob;
		ob.building = true;
		ob.who = who, ob.o = o, ob.type = v->type, ob.hp = v->hit_points, ob.max_hp = v->max_hit_points, ob.own = who == me;
		const uint8_t* tc = kUnitTeamColors[std::clamp(v->color, 0, 8)];
		ob.rgb[0] = tc[0], ob.rgb[1] = tc[1], ob.rgb[2] = tc[2];
		ob.name = [self typeName:v->type];
		const ron::sim::Type& T = _game->type(v->type);
		ob.tex_id = ron::sim::to_utf8(T.tex.id), ob.tex_col = T.tex.col, ob.tex_row = T.tex.row;
		ob.tex_x = T.tex.x > 0 ? T.tex.x : -1, ob.tex_y = T.tex.y > 0 ? T.tex.y : -1;
		if (!v->active && v->construct_time > 0) ob.progress = std::clamp(v->job_counter * 100 / v->construct_time, 0, 100), ob.building_site = true;
		for (const auto& q : v->queue) {
			hud::QueueItem qi;
			qi.type = q.type;
			qi.percent = q.time > 0 ? std::clamp(int(int64_t(q.job_counter) * 100 / q.time), 0, 100) : 0;
			if (ron::sim::is_unit_type(q.type)) [self unitIcon:q.type who:who o:-1 into:qi.tex_id col:qi.tex_col row:qi.tex_row x:qi.tex_x y:qi.tex_y];
			else {
				const ron::sim::Type& Q = _game->type(q.type);
				qi.tex_id = ron::sim::to_utf8(Q.tex.id), qi.tex_col = Q.tex.col, qi.tex_row = Q.tex.row;
			}
			qi.name = [self typeName:q.type];
			ob.queue.push_back(qi);
		}
		ob.repeat = v->repeat;
		s.selection.push_back(ob);
	}
	s.options = [self hudOptions];
	s.res = hud_resources(_game.get(), me);
	if (_game && me >= 0 && me < int(_game->leaders.size())) {
		const ron::sim::Leader& L = _game->leaders[size_t(me)];
		std::string nation;
		if (_simRules && L.tribe >= 0 && size_t(L.tribe) < _simRules->tribes.size()) nation = ron::sim::to_utf8(_simRules->tribes[size_t(L.tribe)].name);
		// The age name: the age tech's display name (Classical = 544 .. Information = 550); Ancient has no tech.
		const std::string age = L.age >= 1 && L.age <= 7 ? [self typeName:543 + L.age] : std::string("Ancient Age");
		s.caption = nation.empty() ? age : nation + " - " + age;
		int bc = 0;
		if (_simRules && L.tribe >= 0 && size_t(L.tribe) < _simRules->tribes.size()) bc = _simRules->tribes[size_t(L.tribe)].build_continent;
		_ui.set_skin(ron::iface_skin_code(L.age, bc));
	}
	s.frame = _game ? _game->frame : 0;
	s.paused = _paused;
	s.graphic_tick = int(_timeMs / 66.0);
	if (const ron::sim::ScriptPresentation* p = [self pres]) {
		s.highlight = p->highlight_active;
		s.hilite_option = p->hilite_option >= 0 ? p->hilite_option : _hiliteOverride;
		s.hilite_object = p->hilite_object;
		if (s.highlight) {
			static std::string highlight_tex;
			if (highlight_tex.empty()) {
				// effects_graphics.xml BUTTONHIGHLIGHT (GraphicPieces::button_high_light).
				std::string file = "art/tutorial_button_highlight_01.tga";
				try {
					ron::for_each_element(ron::parse_xml(_files->read_text("Data/effects_graphics.xml")), "BUTTONHIGHLIGHT",
					                      [&](const ron::XmlElement& e) { file = ron::normalize_game_path(e.get("file")); });
				} catch (const std::exception&) {
				}
				_ui.file_texture(file, &highlight_tex);
			}
			s.highlight_tex = highlight_tex;
		}
	}
	if (_sviewOn) {
		s.pings = _sview.pings();
		if (!s.pings.empty()) _ui.file_texture("art/AttackAlertCircle1.tga", &s.ping_tex);  // EFFECTS/MINIMAP/PING "default"
	}
	return s;
}

- (void)encodeHud:(id<MTLRenderCommandEncoder>)enc width:(NSUInteger)w height:(NSUInteger)h {
	if (!_uiReady) return;
	const float sc = _uiScale > 0 ? _uiScale : 1;
	_uiW = int(std::lround(double(w) / sc));
	_uiH = int(std::lround(double(h) / sc));
	if (!_hudOn) {  // H: no interface, but the game menu still shows
		if (!_gameMenu) return;
		_ui.begin(_uiW, _uiH, sc);
		[self drawGameMenu];
		_ui.encode(enc);
		return;
	}
	[self updateMinimapFog];
	_hudState = [self makeHudState];
	_ui.begin(_uiW, _uiH, sc);
	_hud.layout(_uiW, _uiH);
	if (![self hudVisible]) {  // ui_hide (or H): only the script layers
		if (_sviewOn) _sview.draw(_ui, [self pres], [self scriptEnv]);
		[self drawGameMenu];
		_ui.encode(enc);
		return;
	}
	if (_boxing) {
		// The drag box (post-tonemap, Scene::render step 10): a white frame.
		const CGFloat x0 = std::min(_press.x, _mouse.x), y0 = std::min(_press.y, _mouse.y);
		_ui.frame(float(std::floor(x0)), float(std::floor(y0)), float(std::fabs(_mouse.x - _press.x)), float(std::fabs(_mouse.y - _press.y)), 0xFFFFFFFF);
	}
	_hud.draw(_ui, _hudState);
	// MessageWin, AnimNotice, ScreenArrowSpline, the modal windows (docs/ui-port.md "Script UI").
	if (_sviewOn) _sview.draw(_ui, [self pres], [self scriptEnv]);
	[self drawGameMenu];
	_ui.encode(enc);
}

// ---------------------------------------------------------------- the game menu (docs/ui-port.md "Front end")

- (std::vector<std::string>)gameMenuItems {
	if (_gameMenu == 2) return {"Return to Main Menu", "Keep Watching", "Quit"};
	return {"Resume Game", "Return to Main Menu", "Quit"};
}

- (void)openGameMenu:(int)kind {
	if (!_uiReady) return;
	_gameMenu = kind;
	_gmHover = 0, _gmPress = -1;
	_pressing = _boxing = _hudPress = _rightPress = NO;
}

// MainMenuBase (interface.xml MAINMENU): the 9-piece scroll background bg0..bg8, the title in font 24, a column of
// 173 x 32 buttons (butnormal / buthighlight / butdown), centred on the screen.
- (void)drawGameMenu {
	_gmRects.clear();
	if (!_gameMenu || !_layout) return;
	const ron::XmlElement* mm = nullptr;
	for (const ron::XmlElement& c : _layout->root().children) {
		if (ron::iface_tag_is(c, "MAINMENU")) mm = &c;
	}
	const std::vector<std::string> items = [self gameMenuItems];
	const int bw = 173, bh = 32, gap = 8, pad = 22, titleH = 44;
	const int w = bw + pad * 2, h = titleH + int(items.size()) * (bh + gap) - gap + pad * 2;
	const int x = (_uiW - w) / 2, y = (_uiH - h) / 2 - 40;
	_ui.next_window();
	_ui.fill(0, 0, float(_uiW), float(_uiH), rm::argb(90, 0, 0, 0), rm::UiType::ColorBlend);
	_ui.next_layer();
	ron::IfacePiece bg[9];
	if (mm) {
		for (int k = 0; k < 9; k++) bg[k] = ron::iface_find_piece(*mm, "bg" + std::to_string(k));
	}
	if (bg[0].valid() && bg[4].valid() && bg[8].valid()) {
		const int lw = bg[0].width, rw = bg[2].width, th = bg[0].height, bh2 = bg[6].height;
		const int cx[3] = {x, x + lw, x + w - rw}, cw[3] = {lw, w - lw - rw, rw};
		const int cy[3] = {y, y + th, y + h - bh2}, ch[3] = {th, h - th - bh2, bh2};
		for (int r = 0; r < 3; r++) {
			for (int c = 0; c < 3; c++) _ui.add(bg[r * 3 + c], float(cx[c]), float(cy[r]), float(cw[c]), float(ch[r]));
		}
	} else {
		_ui.fill(float(x), float(y), float(w), float(h), rm::argb(224, 39, 40, 43), rm::UiType::ColorBlend);
	}
	_ui.next_layer();
	const int tf = _ui.font(24, -1), bf = _ui.font(14, -1);
	_ui.text_centered(tf, _gameMenu == 2 ? "Game Over" : "Game Menu", {x, x + w, y + pad - 6, y + pad - 6 + titleH}, 0xFFFFFFFF, 0xFF000000);
	for (size_t i = 0; i < items.size(); i++) {
		const int by = y + pad + titleH + int(i) * (bh + gap);
		const ron::IfaceRect r{x + pad, x + pad + bw, by, by + bh};
		_gmRects.push_back(r);
		const char* kind = _gmPress == int(i) ? "butdown" : _gmHover == int(i) ? "buthighlight" : "butnormal";
		ron::IfacePiece p[3];
		if (mm) {
			for (int k = 0; k < 3; k++) p[k] = ron::iface_find_piece(*mm, std::string(kind) + std::to_string(k));
		}
		_ui.next_layer();
		if (p[0].valid()) _ui.expander(p[0], p[1], p[2], r);
		else _ui.fill(float(r.l), float(r.t), float(r.w()), float(r.h()), rm::argb(255, 70, 70, 70));
		_ui.next_layer();
		_ui.text_centered(bf, items[i], r, 0xFFFFFFFF, 0xFF000000);
	}
}

- (int)gameMenuAt:(CGPoint)p {
	for (size_t i = 0; i < _gmRects.size(); i++) {
		if (_gmRects[i].contains(int(p.x), int(p.y))) return int(i);
	}
	return -1;
}

- (void)gameMenuChoose:(int)i {
	const std::vector<std::string> items = [self gameMenuItems];
	if (i < 0 || size_t(i) >= items.size()) return;
	const std::string& it = items[size_t(i)];
	_gameMenu = 0;
	_lastFrame = 0;  // no catch-up after the pause
	if (it == "Return to Main Menu" && self.onExit) self.onExit(NO);
	else if (it == "Quit") {
		if (self.onExit) self.onExit(YES);
		else [NSApp terminate:nil];
	}
}

- (void)gameMenuKey:(NSEvent*)e {
	NSString* chars = e.charactersIgnoringModifiers;
	const unichar c = chars.length ? [chars characterAtIndex:0] : 0;
	const int n = int([self gameMenuItems].size());
	if (c == NSUpArrowFunctionKey) _gmHover = (std::max(_gmHover, 0) + n - 1) % n;
	else if (c == NSDownArrowFunctionKey) _gmHover = (_gmHover + 1) % n;
	else if (c == '\r' || c == 3) [self gameMenuChoose:std::max(_gmHover, 0)];
	else if (e.keyCode == 53 || e.keyCode == 109) _gameMenu = 0, _lastFrame = 0;  // Esc / F10: back to the game
}

// ---------------------------------------------------------------- building placement (docs/ui-spec.md 4.5)

- (void)startPlacement:(int)type {
	_placeType = type;
	_ghostValid = NO;
	_targeting = -1;
}

- (void)previewPlacementAtWorldX:(float)x y:(float)y {
	if (!_game || _placeType < 0) return;
	const int me = [self localPlayer];
	int32_t sx = int32_t(x), sy = int32_t(y);
	// BuildTypeData::snap_center + blocked_site: the same validation Group::action_build runs (no RNG draws).
	ron::sim::snap_center_who(*_game, _placeType, int32_t(x), int32_t(y), &sx, &sy, me);
	_ghostBlocked = ron::sim::blocked_site(*_game, _placeType, sx, sy, me, -1, nullptr);
	_ghostX = float(sx), _ghostY = float(sy);
	_ghostValid = YES;
	if (getenv("RON_PLACE_DEBUG")) std::fprintf(stderr, "place %d at (%.0f,%.0f) -> snapped (%d,%d) size %dx%d blocked %d\n", _placeType, x, y, sx, sy,
	                                         _game->type(_placeType).x_size, _game->type(_placeType).y_size, _ghostBlocked);
}

// The footprint (BuildTypeOut::draw_template): Template Blend tiles, green checkerboard when the site is valid, orange
// for the soft blocks (city / fort distance, one-per-city, farm, wonder), red otherwise.
- (void)encodeFootprint:(id<MTLRenderCommandEncoder>)enc {
	if (!_game || _placeType < 0 || !_ghostValid) return;
	const ron::sim::Type& T = _game->type(_placeType);
	const int xs = std::max(1, T.x_size), ys = std::max(1, T.y_size);
	const int tx0 = int(_ghostX) / 192 - (xs >> 1), ty0 = int(_ghostY) / 192 - (ys >> 1);
	namespace bk = ron::sim::block;
	const int32_t c = _ghostBlocked;
	const bool soft = c == bk::kOne || c == bk::kOneOther || c == bk::kFarm || c == bk::kCityDistance || c == bk::kFortDistance ||
	                  c == bk::kFortCityDistance || c == bk::kWonder;
	std::vector<ron::ColorVertex> v;
	for (int ty = ty0; ty < ty0 + ys; ty++) {
		for (int tx = tx0; tx < tx0 + xs; tx++) {
			uint8_t r = 0, g = ((tx + ty) & 1) ? 200 : 255, b = 0;
			if (c != 0) r = 255, g = soft ? 140 : 0;
			auto p = [&](int ix, int iy) {
				const float x = float(ix * 192), y = float(iy * 192);
				return ron::ColorVertex{x, y, std::max(0.0f, _terrain.sample_height(x, y)) + 6, 0, 0, 1, 0, 0, r, g, b, 0x70};
			};
			const ron::ColorVertex q[6] = {p(tx, ty), p(tx + 1, ty), p(tx, ty + 1), p(tx, ty + 1), p(tx + 1, ty), p(tx + 1, ty + 1)};
			v.insert(v.end(), q, q + 6);
		}
	}
	static const ron::RenderState& tmpl = *ron::find_render_state("Template Blend");
	rm::DrawUniforms du = rm::draw_uniforms(tmpl, matrix_identity_float4x4);
	_states.bind(enc, tmpl, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	id<MTLBuffer> vb = [_device newBufferWithBytes:v.data() length:v.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_white atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:v.size()];
}

// Options::picked_spot: BUILD with the selected citizens; Ctrl or Shift keeps placing (Ctrl QUEUE_FIRST, Shift QUEUE_LAST).
- (void)placeAt:(CGPoint)p modifiers:(NSEventModifierFlags)m {
	const simd_float2 g = [self groundAt:[self toDrawable:p]];
	[self placeAtWorldX:g.x y:g.y modifiers:m];
}

- (void)placeAtWorldX:(float)wx y:(float)wy modifiers:(NSEventModifierFlags)m {
	if (!_game || _placeType < 0) return;
	const int me = [self localPlayer];
	const simd_float2 g = simd_make_float2(wx, wy);
	[self previewPlacementAtWorldX:wx y:wy];
	std::vector<int32_t> objs;
	for (const auto& [who, o] : _selected) {
		if (who == me) objs.push_back(o);
	}
	const bool ctrl = (m & NSEventModifierFlagControl) != 0, shift = (m & NSEventModifierFlagShift) != 0;
	const ron::sim::QueuePos q = ctrl ? ron::sim::kQueueFirst : shift ? ron::sim::kQueueLast : ron::sim::kQueueNew;
	if (!objs.empty()) {
		_cm.play = me, _cm.play_who = me;
		if (_cm.issue_build(*_game, objs, _placeType, int32_t(g.x), int32_t(g.y), q)) _cm.process_turn(*_game);
		[self stepSimulation:0];
		_curView = ron::sim::make_view(*_game);
		[self syncSimBuildings];
		std::printf("build %d at (%.0f, %.0f) with %zu citizen(s): %s\n", _placeType, g.x, g.y, objs.size(), _ghostBlocked ? "blocked" : "ok");
	}
	if (!ctrl && !shift) _placeType = -1, _buildPage = -1;
}

// ---------------------------------------------------------------- commands from the card

- (void)issueAs:(int)who block:(bool (^)(void))issue {
	if (!_game) return;
	_cm.play = who, _cm.play_who = who;
	if (issue()) _cm.process_turn(*_game);
}

- (std::vector<int32_t>)ownSelectedUnits {
	std::vector<int32_t> v;
	for (const auto& [who, o] : _selected) {
		if (who == [self localPlayer]) v.push_back(o);
	}
	return v;
}

- (std::vector<int32_t>)ownSelectedBuilds {
	std::vector<int32_t> v;
	for (const auto& [who, o] : _selectedBuilds) {
		if (who == [self localPlayer]) v.push_back(o);
	}
	return v;
}

- (void)runOption:(int)option object:(int)object modifiers:(NSEventModifierFlags)m {
	if (!_game) return;
	const int me = [self localPlayer];
	switch (option) {
		case hud::kOptMoveTo: _targeting = option; break;
		case hud::kOptHalt: {
			const std::vector<int32_t> objs = [self ownSelectedUnits];
			[self issueAs:me block:^bool { return _cm.issue_halt(*_game, objs); }];
			break;
		}
		case hud::kOptBuild: case hud::kOptBuildMilitary: case hud::kOptBuildWonder: _buildPage = option; break;
		case 1000:
			// validate_build: a building the player cannot pay for raises ScenarioData::user_warnings bit 0.
			if (ron::sim::can_pay_cost(*_game, object, me, -1, -1, 1) <= 0) _pendingWarnings |= 1;
			[self startPlacement:object];
			break;
		case 65: _buildPage = (_buildPage + 1) % 3; break;  // NEXT
		case 66: _buildPage = -1; break;                     // BACK
		case hud::kOptCancel: _buildPage = -1, _placeType = -1, _targeting = -1; break;
		case hud::kOptTrain: case hud::kOptResearch: {
			// Options::exec: QUEUE_UP (Shift x5 on TRAIN).
			const std::vector<int32_t> objs = [self ownSelectedBuilds];
			const int n = option == hud::kOptTrain && (m & NSEventModifierFlagShift) ? 5 : 1;
			// GroupOut::issue_queue_up: an unaffordable item raises ScenarioData::user_warnings bit 0 (resource_warning).
			if (!objs.empty() && ron::sim::can_pay_cost(*_game, object, me, -1, objs.front(), 1) <= 0) _pendingWarnings |= 1;
			[self issueAs:me block:^bool { return _cm.issue_queue(*_game, objs, object, n); }];
			break;
		}
		default: break;
	}
}

- (void)handleHudAction:(const hud::Action&)a modifiers:(NSEventModifierFlags)m {
	switch (a.kind) {
		case hud::ActionKind::MinimapLook:
			if (!([self pres] && ([self pres]->scroll_lock_flags & 4))) [self lookAtX:a.wx y:a.wy];  // scrolling_lock minimap bit
			break;
		case hud::ActionKind::MinimapOrder: [self orderAtWorldX:a.wx y:a.wy modifiers:m]; break;
		case hud::ActionKind::Option: [self runOption:a.option object:a.object modifiers:m]; break;
		case hud::ActionKind::SelectIndex: {
			if (a.index < int(_hudState.selection.size())) {
				const hud::Object& o = _hudState.selection[size_t(a.index)];
				_selected.clear(), _selectedBuilds.clear();
				(o.building ? _selectedBuilds : _selected).push_back({o.who, o.o});
				[self selectionChanged];
			}
			break;
		}
		case hud::ActionKind::QueueItem: {
			// OPTION_QUEUE: remove the clicked queue item.
			if (!_selectedBuilds.empty() && _selectedBuilds.front().first == [self localPlayer]) {
				const int32_t o = _selectedBuilds.front().second;
				const int idx = a.index;
				[self issueAs:[self localPlayer] block:^bool { return _cm.issue_unqueue(*_game, o, idx); }];
			}
			break;
		}
		default: break;
	}
}

- (void)selectionChanged {
	_buildPage = -1, _targeting = -1, _placeType = -1;
	[self updateTitle];
}

// A right-click order at a world point: units move (MOVE_TO; Shift QUEUE_LAST, Alt QUEUE_FIRST); own buildings set their
// rally point (GATHER_POINT).
- (void)orderAtWorldX:(float)x y:(float)y modifiers:(NSEventModifierFlags)m {
	if (!_game) return;
	const int me = [self localPlayer];
	const int32_t ix = int32_t(std::lround(std::clamp(x, 0.0f, _mesh.width - 1))), iy = int32_t(std::lround(std::clamp(y, 0.0f, _mesh.height - 1)));
	const ron::sim::QueuePos q = (m & NSEventModifierFlagShift) ? ron::sim::kQueueLast : (m & NSEventModifierFlagOption) ? ron::sim::kQueueFirst
	                                                                                                                     : ron::sim::kQueueNew;
	if (!_selected.empty()) {
		const std::vector<int32_t> objs = [self ownSelectedUnits];
		[self issueAs:me block:^bool { return _cm.issue_move_to(*_game, objs, ix, iy, q); }];
	} else if (!_selectedBuilds.empty()) {
		const std::vector<int32_t> objs = [self ownSelectedBuilds];
		const bool add = (m & NSEventModifierFlagShift) != 0;
		[self issueAs:me block:^bool { return _cm.issue_gather_point(*_game, objs, ix, iy, 0, add); }];
		std::printf("rally %zu building(s) at (%d, %d)\n", objs.size(), ix, iy);
	}
}

// ---------------------------------------------------------------- selection (docs/ui-spec.md 4.1)

- (CGPoint)toDrawable:(CGPoint)p {
	return CGPointMake(p.x * _uiScale, p.y * _uiScale);
}

// A drawn unit's pick point in UI pixels (its middle rather than its feet).
- (simd_float2)uiPointOfUnit:(const SimUnitDrawn&)d {
	const simd_float3 base = simd_make_float3(d.x, d.y, std::max(0.0f, _terrain.sample_height(d.x, d.y)));
	return [self screenOf:base + simd_make_float3(0, 0, 60)] / _uiScale;
}

- (simd_float2)uiPointOfBuilding:(const PlacedBuilding&)b {
	return [self screenOf:simd_make_float3(b.x, b.y, std::max(0.0f, _terrain.sample_height(b.x, b.y)))] / _uiScale;
}

- (BOOL)buildingVisible:(const PlacedBuilding&)b {
	return b.who >= 0 && (!_game || !_fogOn || ron::sim::build_seen_by(*_game, _game->local_play, b.who, b.o));
}

- (BOOL)selectWho:(int)who objects:(const std::vector<int32_t>&)objs buildings:(BOOL)builds {
	_selected.clear(), _selectedBuilds.clear();
	for (int32_t o : objs) (builds ? _selectedBuilds : _selected).push_back({who, o});
	[self selectionChanged];
	return !objs.empty();
}

- (void)setBuildPage:(int)page {
	_buildPage = page;
}

- (void)queueWho:(int)who building:(int)o type:(int)type count:(int)n {
	std::vector<int32_t> objs{o};
	[self issueAs:who block:^bool { return _cm.issue_queue(*_game, objs, type, std::max(1, n)); }];
}

// The viewing seat (console.play): seat-local, never feeds the simulation.
- (void)setLocalPlayer:(int)who {
	if (_game && who >= 0 && who < 8) _game->local_play = who;
}

// The object under a UI point: the nearest drawn unit within 20 px, else a seen building whose footprint is near the
// ground point. Returns 1 unit, 2 building, 0 nothing.
- (int)pickAt:(CGPoint)p who:(int32_t&)who o:(int32_t&)o type:(int32_t&)type {
	float best = 20;
	int kind = 0;
	for (const SimUnitDrawn& d : _drawnUnits) {
		const float dist = simd_distance([self uiPointOfUnit:d], simd_make_float2(float(p.x), float(p.y)));
		if (dist < best) best = dist, who = d.who, o = d.o, type = d.type, kind = 1;
	}
	if (kind) return kind;
	const simd_float2 g = [self groundAt:[self toDrawable:p]];
	float bestw = 1e9f;
	for (const PlacedBuilding& b : _placed) {
		if (![self buildingVisible:b]) continue;
		const ron::sim::BuildView* v = [self buildView:b.who o:b.o];
		const int32_t t = v ? v->type : -1;
		const float r = t >= 0 ? float(std::max(_game->type(t).x_size, _game->type(t).y_size)) * 96.0f + 96.0f : 400.0f;
		const float dist = simd_distance(g, simd_make_float2(b.x, b.y));
		if (dist < r && dist < bestw) bestw = dist, who = b.who, o = b.o, type = t, kind = 2;
	}
	return kind;
}

// Console::left_click: no modifier selects only the object, Shift adds, Ctrl toggles; a double click selects every
// on-screen object of the same owner and type (Shift keeps the old selection). Units and buildings never mix.
- (void)clickSelectAt:(CGPoint)p modifiers:(NSEventModifierFlags)m double:(BOOL)dbl {
	int32_t who = -1, o = -1, type = -1;
	const int kind = [self pickAt:p who:who o:o type:type];
	const bool shift = (m & NSEventModifierFlagShift) != 0, ctrl = (m & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) != 0;
	if (!kind) {
		if (!shift && !ctrl) _selected.clear(), _selectedBuilds.clear();
		[self selectionChanged];
		return;
	}
	auto& list = kind == 1 ? _selected : _selectedBuilds;
	auto& other = kind == 1 ? _selectedBuilds : _selected;
	other.clear();
	const auto key = std::make_pair(who, o);
	if (dbl) {
		if (!shift) list.clear();
		const float bottom = float(_hud.bar_top());
		auto on_screen = [&](simd_float2 sp) { return sp.x >= 0 && sp.y >= 0 && sp.x < _uiW && sp.y < (_hudOn ? bottom : _uiH); };
		if (kind == 1) {
			for (const SimUnitDrawn& d : _drawnUnits) {
				if (d.who == who && d.type == type && on_screen([self uiPointOfUnit:d]) && std::find(list.begin(), list.end(), std::make_pair(d.who, d.o)) == list.end())
					list.push_back({d.who, d.o});
			}
		} else {
			for (const PlacedBuilding& b : _placed) {
				const ron::sim::BuildView* v = [self buildingVisible:b] ? [self buildView:b.who o:b.o] : nullptr;
				if (v && v->who == who && v->type == type && on_screen([self uiPointOfBuilding:b])) list.push_back({b.who, b.o});
			}
		}
	} else if (ctrl) {
		auto it = std::find(list.begin(), list.end(), key);
		if (it != list.end()) list.erase(it);
		else list.push_back(key);
	} else if (shift) {
		if (std::find(list.begin(), list.end(), key) == list.end()) list.push_back(key);
	} else {
		list.assign(1, key);
	}
	if (list.size() > 128) list.resize(128);
	[self selectionChanged];
}

// Console::on_left_up box select: units first, buildings only when no unit is boxed; the viewer's own objects win, other
// players' only if none of his are boxed; one owner, at most 128 (SelectGroup::add). Shift adds within the category.
- (void)boxSelect:(CGRect)r modifiers:(NSEventModifierFlags)m {
	const bool shift = (m & NSEventModifierFlagShift) != 0;
	const int me = [self localPlayer];
	std::map<int32_t, std::vector<std::pair<int32_t, int32_t>>> units, builds;
	for (const SimUnitDrawn& d : _drawnUnits) {
		const simd_float2 sp = [self uiPointOfUnit:d];
		if (CGRectContainsPoint(r, CGPointMake(sp.x, sp.y))) units[d.who].push_back({d.who, d.o});
	}
	if (units.empty()) {
		for (const PlacedBuilding& b : _placed) {
			if (![self buildingVisible:b]) continue;
			const simd_float2 sp = [self uiPointOfBuilding:b];
			if (CGRectContainsPoint(r, CGPointMake(sp.x, sp.y))) builds[b.who].push_back({b.who, b.o});
		}
	}
	auto pick = [&](auto& by_owner) -> std::vector<std::pair<int32_t, int32_t>> {
		if (by_owner.empty()) return {};
		auto it = by_owner.find(me);
		return it != by_owner.end() ? it->second : by_owner.begin()->second;
	};
	const bool is_units = !units.empty();
	std::vector<std::pair<int32_t, int32_t>> found = is_units ? pick(units) : pick(builds);
	if (found.empty()) {
		if (!shift) _selected.clear(), _selectedBuilds.clear();
		[self selectionChanged];
		return;
	}
	auto& list = is_units ? _selected : _selectedBuilds;
	(is_units ? _selectedBuilds : _selected).clear();
	if (!shift || (!list.empty() && list.front().first != found.front().first)) list.clear();
	for (const auto& k : found) {
		if (list.size() >= 128) break;
		if (std::find(list.begin(), list.end(), k) == list.end()) list.push_back(k);
	}
	[self selectionChanged];
}

// ---------------------------------------------------------------- mouse

- (void)uiMouseDown:(CGPoint)p right:(BOOL)right modifiers:(NSEventModifierFlags)m clicks:(NSInteger)clicks {
	_mouse = p;
	_mouseInside = YES;
	if (_gameMenu) {
		_gmPress = right ? -1 : [self gameMenuAt:p];
		return;
	}
	if (_sviewOn && [self modalMouse:p up:NO]) return;
	if ([self hudVisible] && _hud.captures(int(p.x), int(p.y))) {
		_hudPress = YES;
		[self handleHudAction:_hud.mouse_down(int(p.x), int(p.y), right, _hudState) modifiers:m];
		return;
	}
	_hudPress = NO;
	_press = p;
	if (right) {
		_rightPress = YES, _rightDragged = NO;
		return;
	}
	_pressing = YES, _boxing = NO, _pressMs = _timeMs, _pressMods = m;
	_pressClicks = clicks;
}

- (void)uiMouseDragged:(CGPoint)p right:(BOOL)right delta:(CGPoint)d {
	_mouse = p;
	if (_gameMenu) {
		_gmHover = [self gameMenuAt:p];
		return;
	}
	if (_hudPress) {
		[self handleHudAction:_hud.mouse_drag(int(p.x), int(p.y), _hudState) modifiers:0];
		return;
	}
	const float dist = float(std::hypot(p.x - _press.x, p.y - _press.y));
	if (right) {
		// Click vs drag: 6 px for the right button. A right drag scrolls the map (the formation drag is not ported).
		if (_rightPress && dist > 6) _rightDragged = YES;
		if (_rightDragged) [self scrollByPixelsX:float(-d.x * _uiScale) y:float(d.y * _uiScale)];
		return;
	}
	// Left: 20 px once held more than 7 graphic ticks (462 ms), else 64 px (Console::init / on_mouse_move).
	const float threshold = _timeMs - _pressMs > 7 * 66.0 ? 20 : 64;
	if (_pressing && !_boxing && dist > threshold && _placeType < 0 && _targeting < 0) _boxing = YES;
}

- (void)uiMouseUp:(CGPoint)p right:(BOOL)right modifiers:(NSEventModifierFlags)m {
	_mouse = p;
	if (_gameMenu) {
		const int i = [self gameMenuAt:p];
		const int pressed = _gmPress;
		_gmPress = -1;
		if (!right && i >= 0 && i == pressed) [self gameMenuChoose:i];
		return;
	}
	if (_sviewOn && (_sview.modal()) && [self modalMouse:p up:YES]) return;
	if (_hudPress) {
		_hudPress = NO;
		[self handleHudAction:_hud.mouse_up(int(p.x), int(p.y), right, _hudState) modifiers:m];
		return;
	}
	if (right) {
		if (_rightPress && !_rightDragged) {
			if (_placeType >= 0 || _targeting >= 0) {
				_placeType = -1, _targeting = -1;  // a right click cancels a pending placement or target
			} else if (!_selected.empty()) {
				[self commandMoveAt:[self toDrawable:p]];
			} else if (!_selectedBuilds.empty()) {
				const simd_float2 g = [self groundAt:[self toDrawable:p]];
				[self orderAtWorldX:g.x y:g.y modifiers:m];
			}
		}
		_rightPress = NO;
		return;
	}
	if (!_pressing) return;
	_pressing = NO;
	if (_placeType >= 0) {
		[self placeAt:p modifiers:m];
	} else if (_targeting >= 0) {
		const simd_float2 g = [self groundAt:[self toDrawable:p]];
		if (_targeting == hud::kOptMoveTo) [self orderAtWorldX:g.x y:g.y modifiers:m];
		_targeting = -1;
	} else if ([self pres] && [self pres]->mouse_selection_disabled) {
		_boxing = NO;  // mouse_selection_disable: clicks and boxes select nothing
	} else if (_boxing) {
		_boxing = NO;
		[self boxSelect:CGRectMake(std::min(_press.x, p.x), std::min(_press.y, p.y), std::fabs(p.x - _press.x), std::fabs(p.y - _press.y))
		      modifiers:m];
	} else {
		[self clickSelectAt:p modifiers:m double:_pressClicks >= 2];
	}
}

- (void)uiMouseMoved:(CGPoint)p {
	_mouse = p;
	_mouseInside = YES;
	if (_gameMenu) {
		const int i = [self gameMenuAt:p];
		if (i >= 0) _gmHover = i;
		return;
	}
	_hud.mouse_move(int(p.x), int(p.y));
	if (_sviewOn && _sview.popup_open()) _sview.popup().hover = _sview.popup_button_at(int(p.x), int(p.y));
	if (_placeType >= 0 && !([self hudVisible] && _hud.captures(int(p.x), int(p.y)))) {
		const simd_float2 g = [self groundAt:[self toDrawable:p]];
		[self previewPlacementAtWorldX:g.x y:g.y];
	}
}

// Camera::zoom_in(x, y) / zoom_out: one level per step, toward the cursor; in to 6, out to 4.
- (void)zoomBy:(int)d toward:(CGPoint)p {
	if ([self pres] && ([self pres]->zoom_lock_flags & 1)) return;  // zooming_lock
	const int z = std::clamp(_zoom + d, d < 0 ? std::min(_zoom, 4) : 0, 6);
	if (z == _zoom) return;
	const CGPoint dp = [self toDrawable:p];
	const simd_float2 before = [self groundAt:dp];
	_zoom = z;
	if ([self pres] && ([self pres]->scroll_lock_flags & 1)) {  // Camera::zoom_in: no pan toward the cursor while locked
		[self updateTitle];
		return;
	}
	const simd_float2 after = [self groundAt:dp];
	_lookAt.x = std::clamp(_lookAt.x + before.x - after.x, 0.0f, _mesh.width);
	_lookAt.y = std::clamp(_lookAt.y + before.y - after.y, 0.0f, _mesh.height);
	[self updateTitle];
}

// A mouse wheel notch zooms (ZOOM_IN3 / ZOOM_OUT3); trackpad scrolling pans the map.
- (void)uiScrollWheel:(NSEvent*)e at:(CGPoint)p {
	if (_gameMenu) return;
	if (!e.hasPreciseScrollingDeltas) {
		if (e.scrollingDeltaY != 0) [self zoomBy:(e.scrollingDeltaY > 0 ? 1 : -1) toward:p];
		return;
	}
	[self scrollByPixelsX:float(-e.scrollingDeltaX * _uiScale) y:float(e.scrollingDeltaY * _uiScale)];
}

- (void)uiMagnify:(float)amount at:(CGPoint)p {
	if (_gameMenu) return;
	_magnify += amount;
	if (std::fabs(_magnify) >= 0.15f) {
		[self zoomBy:(_magnify > 0 ? 1 : -1) toward:p];
		_magnify = 0;
	}
}

// Camera::check_scroll @008440f0: a 2 px edge band; the left and right edges only above the HUD top - 40 px. Step
// min(1, dt / 67 * 0.5) * 63.9936 * speed (1.0) * scroll_speeds[zoom] world units along the camera axes.
- (void)edgeScroll:(double)dtMs {
	if (_gameMenu) return;
	NSWindow* win = self.view.window;
	if (!win || !win.isKeyWindow || _hudPress || _rightDragged) return;
	if ([self pres] && ([self pres]->scroll_lock_flags & 1)) return;  // scrolling_lock (Camera::check_scroll)
	if (_inPopup || (_sviewOn && _sview.modal())) return;
	const NSPoint wp = [self.view convertPoint:[win mouseLocationOutsideOfEventStream] fromView:nil];
	const NSRect b = self.view.bounds;
	if (!NSPointInRect(wp, b)) return;
	const float x = float(wp.x), y = float(b.size.height - wp.y), W = float(b.size.width), H = float(b.size.height);
	static const float speeds[7] = {48, 32, 24, 16, 12, 9, 8};
	const float step = float(std::min(1.0, dtMs / 67.0 * 0.5) * 63.9936) * speeds[std::clamp(_zoom, 0, 6)] * (_boxing ? 0.25f : 1.0f);
	const bool sides = ![self hudVisible] || y < float(_hud.bar_top() - 40) || _boxing;
	float dx = 0, dy = 0;
	if (x < 2 && sides) dx = -1;
	if (x >= W - 2 && sides) dx = 1;
	if (y < 2) dy = 1;
	if (y >= H - 2) dy = -1;
	if (dx == 0 && dy == 0) return;
	const simd_float3 ground_up = simd_normalize(simd_make_float3(kUp.x, kUp.y, 0));
	const simd_float3 right = simd_normalize(simd_make_float3(kRight.x, kRight.y, 0));
	_lookAt += (right * dx + ground_up * dy) * step;
	_lookAt.x = std::clamp(_lookAt.x, 0.0f, _mesh.width);
	_lookAt.y = std::clamp(_lookAt.y, 0.0f, _mesh.height);
}

// ---------------------------------------------------------------- control groups (docs/ui-spec.md 4.3)

// Ctrl+N stores the selection (or, with nothing selected, bookmarks the camera); Ctrl+Shift+N erases; N recalls (a
// second press within 500 ms centres the camera on the group); Shift+N adds the group. Seat-local for now.
- (BOOL)handleGroupKey:(NSEvent*)e {
	static const unsigned short codes[10] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};  // kVK_ANSI_0..9
	int n = -1;
	for (int i = 0; i < 10; i++) {
		if (e.keyCode == codes[i]) n = i;
	}
	if (n < 0) return NO;
	const NSEventModifierFlags m = e.modifierFlags;
	const bool ctrl = (m & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) != 0, shift = (m & NSEventModifierFlagShift) != 0;
	ControlGroup& g = _groups[n];
	if (ctrl && shift) {
		g = ControlGroup{};
	} else if (ctrl) {
		g = ControlGroup{};
		if (_selected.empty() && _selectedBuilds.empty()) g.bookmark = true, g.at = _lookAt, g.zoom = _zoom;
		else g.units = _selected, g.builds = _selectedBuilds;
	} else if ([self pres] && [self pres]->hotkey_selection_disabled) {
		// hotkey_selection_disable: control groups do not recall
	} else if (g.bookmark) {
		_lookAt = g.at, _zoom = g.zoom;
	} else if (!g.units.empty() || !g.builds.empty()) {
		auto alive_units = [&] {
			std::vector<std::pair<int32_t, int32_t>> v;
			for (const auto& k : g.units) {
				const ron::sim::UnitView* u = [self unitView:k.first o:k.second];
				if (u && u->alive) v.push_back(k);
			}
			return v;
		};
		g.units = alive_units();
		if (shift) {
			for (const auto& k : g.units) {
				if (std::find(_selected.begin(), _selected.end(), k) == _selected.end()) _selected.push_back(k);
			}
		} else {
			if (_lastGroupKey == n && _timeMs - _lastGroupMs < 500) {
				float sx = 0, sy = 0, c = 0;
				for (const auto& k : g.units) {
					if (const ron::sim::UnitView* u = [self unitView:k.first o:k.second]) sx += float(u->x), sy += float(u->y), c++;
				}
				for (const auto& k : g.builds) {
					if (const ron::sim::BuildView* b = [self buildView:k.first o:k.second]) sx += float(b->x), sy += float(b->y), c++;
				}
				if (c > 0) [self lookAtX:sx / c y:sy / c];
			}
			_selected = g.units, _selectedBuilds = g.builds;
			[self syncSimBuildings];
		}
		[self selectionChanged];
	}
	_lastGroupKey = n, _lastGroupMs = _timeMs;
	return YES;
}

// ---------------------------------------------------------------- scenario scripts (docs/ui-port.md "Script UI")

- (const ron::sim::ScriptPresentation*)pres {
	return _game ? ron::sim::script_presentation(*_game) : nullptr;
}

// The interface is drawn and takes the mouse unless the user turned it off (H) or a script hid it (ui_hide).
- (BOOL)hudVisible {
	const ron::sim::ScriptPresentation* p = [self pres];
	return _hudOn && !(p && p->ui_hidden);
}

- (void)setUiWidth:(int)w height:(int)h scale:(float)scale {
	_uiScale = scale > 0 ? scale : 1;
	_uiW = int(std::lround(w / _uiScale));
	_uiH = int(std::lround(h / _uiScale));
	_drawW = CGFloat(w), _drawH = CGFloat(h);
	if (_hudOn) _hud.layout(_uiW, _uiH);
}

- (void)setScriptLog:(BOOL)on {
	_scriptLog = on;
}

- (void)setMouseInside:(BOOL)inside {
	_mouseInside = inside;
}

// Debugging aid (RON_POPUP_TEST="text"): a two-button popup left open for a snapshot of its look.
- (void)testPopup:(const char*)text {
	ron::sim::ScriptEvent e;
	e.text = text, e.text2 = "Yes", e.text3 = "No", e.a = 2;
	if (_sviewOn) _sview.open_popup(e);
}

// Headless: the mouse over a world point (ground level), as if the player pointed there.
- (void)setCursorWorldX:(float)x y:(float)y {
	const float z = std::max(0.0f, _terrain.sample_height(x, y));
	const simd_float2 sp = [self screenOf:simd_make_float3(x, y, z)] / (_uiScale > 0 ? _uiScale : 1);
	_mouse = CGPointMake(sp.x, sp.y);
	_mouseInside = YES;
}

- (void)runCardOption:(int)option object:(int)object {
	[self runOption:option object:object modifiers:0];
}

// The window is up: real time drives the graphic clock, sounds and music play (Data/sound.xml TRACKS).
- (void)startInteractive {
	_headless = NO;
	_drawW = _drawH = 0;
	_audio = std::make_unique<ron::audio::Audio>();
	try {
		std::map<std::string, std::vector<std::string>> moods;
		std::string win, lose;
		const ron::XmlElement doc = ron::parse_xml(_files->read_text("Data/sound.xml"));
		auto file_of = [&](const ron::XmlElement& snd) { return _files->resolve(ron::normalize_game_path(snd.get("file"))); };
		ron::for_each_element(doc, "TRACKS", [&](const ron::XmlElement& tracks) {
			if (!moods.empty()) return;
			for (const ron::XmlElement& c : tracks.children) {
				if (c.name == "WIN" && !c.children.empty()) win = file_of(c.children.front());
				if (c.name == "LOSE" && !c.children.empty()) lose = file_of(c.children.front());
				if (c.name != "TRIBE" || ron::to_lower(c.get("tribe")) != "default") continue;
				for (const ron::XmlElement& age : c.children) {
					for (const ron::XmlElement& mood : age.children) {
						if (mood.name != "MOOD") continue;
						// JukeBox MoodIndex by name: BATTLE_VICTORY = winning, BATTLE_DEFEAT = losing, ECONOMIC = economic.
						const std::string m = mood.get("mood");
						const std::string key = m == "BATTLE_VICTORY" ? "winning" : m == "BATTLE_DEFEAT" ? "losing" : m == "ECONOMIC" ? "economic" : "";
						if (key.empty()) continue;
						for (const ron::XmlElement& snd : mood.children) {
							const std::string f = file_of(snd);
							if (!f.empty()) moods[key].push_back(f);
						}
					}
				}
			}
		});
		_audio->set_music(moods, win, lose);
		_audio->update(_timeMs);
		_audio->music_start();
	} catch (const std::exception& e) {
		std::fprintf(stderr, "music unavailable: %s\n", e.what());
	}
}

// AppKit key codes -> Windows virtual keys for Game::keystate (key_down reads VkKeyScan of a character).
static int vk_of(NSEvent* e) {
	switch (e.keyCode) {
		case 123: return 0x25;  // left
		case 124: return 0x27;  // right
		case 125: return 0x28;  // down
		case 126: return 0x26;  // up
		case 36: return 0x0D;   // return
		case 53: return 0x1B;   // escape
		case 48: return 0x09;   // tab
		case 49: return 0x20;   // space
		case 51: return 0x08;   // backspace
		default: break;
	}
	NSString* c = e.charactersIgnoringModifiers;
	if (c.length == 0) return -1;
	unichar ch = [c characterAtIndex:0];
	if (ch >= 'a' && ch <= 'z') ch = unichar(ch - 32);
	return ch < 256 ? int(ch) : -1;
}

- (void)scriptKey:(NSEvent*)e down:(BOOL)down {
	const int vk = vk_of(e);
	if (vk >= 0) _keys[size_t(vk)] = down ? 0x80 : 0;
}

- (void)scriptFlags:(NSEventModifierFlags)m {
	_keys[0x10] = (m & NSEventModifierFlagShift) ? 0x80 : 0;
	_keys[0x11] = (m & NSEventModifierFlagControl) ? 0x80 : 0;
	_keys[0x12] = (m & NSEventModifierFlagOption) ? 0x80 : 0;
}

// The type's build menu page (0 civic, 1 military, 2 wonders) for the armed BUILD option.
- (int)pageOfType:(int)t {
	if (!_game || t < 0) return 0;
	const int cat = _game->type(t).cat;
	return cat >= 0 && cat <= 2 ? cat : 0;
}

// ScriptInput (sim/script_ui.hpp) from ronmap's state, written between frames. Single player: the builtins keep the
// original's multiplayer guards themselves (semaphore byte0 & 4), so the input is filled the same way either way.
- (void)fillScriptInput {
	if (!_game) return;
	ron::sim::ScriptInput* in = ron::sim::script_input(*_game);
	if (!in) return;
	in->attached = true;
	// console.play's SelectGroup: the owner and the captains of the selection.
	in->select_who = -1;
	in->selected.clear();
	const auto& sel = !_selected.empty() ? _selected : _selectedBuilds;
	if (!sel.empty()) {
		in->select_who = sel.front().first;
		for (const auto& [who, o] : sel) {
			if (who == in->select_who) in->selected.push_back(o);
		}
	}
	// Options: the armed command and the build options panel.
	in->option = -1, in->option_object = -1, in->mode_data = 0, in->selecting_spot = false, in->build_options = false;
	if (_targeting >= 0) in->option = _targeting, in->selecting_spot = true;
	if (_buildPage >= 0) in->build_options = true, in->mode_data = _buildPage, in->option = _buildPage;
	if (_placeType >= 0) {
		const int page = _buildPage >= 0 ? _buildPage : [self pageOfType:_placeType];
		in->option = page, in->option_object = _placeType, in->selecting_spot = true, in->build_options = true, in->mode_data = page;
	}
	// Screen, interface rectangles (get_button_*), the objectives box (get_objectives_*).
	in->screen_w = _uiW, in->screen_h = _uiH;
	in->iface_rects.clear();
	if (_hudOn) {
		_hud.layout(_uiW, _uiH);
		for (const auto& [name, r] : _hud.named_rects()) in->iface_rects[name] = ron::sim::ScriptRect{r.l, r.r, r.t, r.b};
	}
	if (_headless && _sviewOn) [self layoutScriptView];  // no frames are drawn: lay the objectives box out anyway
	in->objectives_rect = _sview.objectives_rect();
	// Console: the tile under the cursor and whether it is over the interface.
	in->cursor_tx = in->cursor_ty = -1;
	in->cursor_over_iface = false;
	if (_mouseInside && _uiW > 0) {
		const simd_float2 g = [self groundAt:[self toDrawable:_mouse]];
		if (g.x >= 0 && g.y >= 0 && g.x < _mesh.width && g.y < _mesh.height) in->cursor_tx = int(g.x / 192), in->cursor_ty = int(g.y / 192);
		in->cursor_over_iface = [self hudVisible] && _mouse.y > _hud.bar_top();
	}
	// Camera.
	in->camera_x = _lookAt.x, in->camera_y = _lookAt.y;
	in->zoom_level = _zoom;
	in->camera_panning = _pan.panning != 0;
	__weak MapRenderer* weakSelf = self;
	in->on_screen = [weakSelf](int32_t x, int32_t y) {
		MapRenderer* me = weakSelf;
		if (!me) return false;
		const CGSize size = [me drawSize];
		const float z = std::max(0.0f, me->_terrain.sample_height(float(x), float(y)));
		const simd_float2 sp = [me screenOf:simd_make_float3(float(x), float(y), z)];
		return sp.x >= 0 && sp.y >= 0 && sp.x < float(size.width) && sp.y < float(size.height);
	};
	in->keystate = _keys;
	in->user_warnings |= _pendingWarnings;
	_pendingWarnings = 0;
	// ScenarioData::sound: "still playing" while our player plays it; otherwise the WAV-length model decides, so a sound
	// the script starts within a frame is never reported finished before it was heard.
	in->sound_state = (_audio && _audio->voice_playing()) ? 0 : -1;
	in->graphic_clock = int32_t(_timeMs);
	in->player_profile_name = "Player";
}

- (scriptview::Env)scriptEnv {
	scriptview::Env env;
	env.ui_w = _uiW, env.ui_h = _uiH;
	env.tick = int(_timeMs / 66.0);
	env.ms = _timeMs;
	env.local = [self localPlayer];
	env.game = _game.get();
	env.hud = _hudOn ? &_hud : nullptr;
	env.hud_visible = [self hudVisible];
	__weak MapRenderer* weakSelf = self;
	env.project = [weakSelf](float wx, float wy, float& x, float& y) {
		MapRenderer* me = weakSelf;
		if (!me) return false;
		const float z = std::max(0.0f, me->_terrain.sample_height(std::clamp(wx, 0.0f, me->_mesh.width), std::clamp(wy, 0.0f, me->_mesh.height)));
		const simd_float2 sp = [me screenOf:simd_make_float3(wx, wy, z)] / me->_uiScale;
		x = sp.x, y = sp.y;
		return true;
	};
	return env;
}

- (scriptview::Callbacks)scriptCallbacks {
	scriptview::Callbacks cb;
	__weak MapRenderer* weakSelf = self;
	cb.play_voice = [weakSelf](const std::string& path) {
		MapRenderer* me = weakSelf;
		if (me && me->_audio) me->_audio->play_voice(path);
	};
	cb.stop_voice = [weakSelf]() {
		MapRenderer* me = weakSelf;
		if (me && me->_audio) me->_audio->stop_voice();
	};
	cb.music_mood = [weakSelf](const std::string& mood) {
		MapRenderer* me = weakSelf;
		if (me && me->_audio) me->_audio->set_music_mood(mood);
	};
	cb.play_effect = [weakSelf](const std::string& path) {
		MapRenderer* me = weakSelf;
		if (me && me->_audio) me->_audio->play_effect(path);
	};
	cb.camera = [weakSelf](int kind, int x, int y, int zoom) {
		MapRenderer* me = weakSelf;
		if (me) [me cameraRequest:kind x:x y:y zoom:zoom];
	};
	cb.clear_selection = [weakSelf]() {
		MapRenderer* me = weakSelf;
		if (!me) return;
		me->_selected.clear(), me->_selectedBuilds.clear();
		[me selectionChanged];
	};
	cb.pause = [weakSelf](bool on) {
		MapRenderer* me = weakSelf;
		if (me && !me->_headless) me->_paused = on;
	};
	cb.highlight_option = [weakSelf](int option) {
		MapRenderer* me = weakSelf;
		if (me) me->_hiliteOverride = option;
	};
	cb.screenshot = [](const std::string& file) { std::printf("script: take_screenshot \"%s\" (not written)\n", file.c_str()); };
	return cb;
}

// After each Game::do_frame: the presentation queue, the local game-over, and --script-log output.
- (void)consumeScript {
	if (!_game) return;
	const ron::sim::ScriptPresentation* p = [self pres];
	const scriptview::Env env = [self scriptEnv];
	const scriptview::Callbacks cb = [self scriptCallbacks];
	if (p && _scriptLog) [self logScript:*p];
	if (p && _sviewOn) _sview.consume(*p, env, cb);
	if (p && !p->highlight_active) _hiliteOverride = -1;
	for (; _gameEventsSeen < _game->events.size(); _gameEventsSeen++) {
		const ron::sim::GameEvent& ev = _game->events[_gameEventsSeen];
		const int me = [self localPlayer];
		const bool won = ev.kind == 3 && ev.who == me, lost = ev.kind == 2 && ev.who == me;
		if (!won && !lost) continue;
		const std::string msg = p ? (won ? p->victory_message : p->defeat_message) : std::string();
		std::printf("frame %d: %s%s%s\n", _game->frame, won ? "victory" : "defeat", msg.empty() ? "" : ": ", msg.c_str());
		if (_sviewOn) _sview.game_over(won, msg, env, cb);
		if (_audio) {
			if (won) _audio->music_win();
			else _audio->music_lose();
		}
	}
}

- (void)logScript:(const ron::sim::ScriptPresentation&)p {
	static const char* names[] = {"game message", "message", "instruction", "feedback", "chat", "notice", "bubble",
	                              "popup", "sound", "stop sound", "music mood", "ping", "clear pings", "camera",
	                              "clear messages", "goal dialog", "screenshot", "pause", "results"};
	for (const ron::sim::ScriptEvent& e : p.events) {
		if (e.seq <= _logSeq) continue;
		_logSeq = e.seq;
		std::printf("  f%-5d SCRIPT %s", e.frame, names[std::min<int>(e.kind, 18)]);
		if (!e.text.empty()) std::printf(" \"%s\"", e.text.c_str());
		if (!e.text2.empty()) std::printf(" [%s]", e.text2.c_str());
		if (e.kind == ron::sim::ScriptEvent::kPing || e.kind == ron::sim::ScriptEvent::kCamera) std::printf(" at (%d, %d)", e.x, e.y);
		std::printf("\n");
	}
	for (size_t k = _logObjectives; k < p.objectives.size(); k++)
		std::printf("  f%-5d SCRIPT objective added '%s': \"%s\"\n", p.objectives[k].frame, p.objectives[k].id.c_str(), p.objectives[k].text.c_str());
	_logObjectives = p.objectives.size();
	for (const ron::sim::ScriptObjective& o : p.objectives) {
		if (!o.completed) continue;
		bool known = false;
		for (const auto& d : _logDone) known = known || (d.first == o.id && d.second == o.frame);
		if (known) continue;
		_logDone.push_back({o.id, o.frame});
		std::printf("  f%-5d SCRIPT objective complete '%s'\n", o.completed, o.id.c_str());
	}
}

// A headless layout pass of the script layers (fonts need a UI frame): fills the objectives box for get_objectives_*.
- (void)layoutScriptView {
	if (_uiW <= 0) return;
	_ui.begin(_uiW, _uiH, _uiScale > 0 ? _uiScale : 1);
	_sview.draw(_ui, [self pres], [self scriptEnv]);
}

// Camera moves from the scripts: pan_to (panning = 1), set_loc (jump), to_zoom_level (one level per check_zoom).
- (void)cameraRequest:(int)kind x:(int)x y:(int)y zoom:(int)zoom {
	using CR = ron::sim::CameraRequest;
	if ((kind == CR::kPan || kind == CR::kPanZoom) && x >= 0) {
		_pan.panning = 1, _pan.to_x = x, _pan.to_y = y, _pan.from_x = int(_lookAt.x), _pan.from_y = int(_lookAt.y);
	}
	if (kind == CR::kJump && x >= 0) {
		_pan.panning = 0;
		[self lookAtX:float(x) y:float(y)];
	}
	if ((kind == CR::kZoom || kind == CR::kPanZoom) && zoom >= 0) _pan.zooming = true, _pan.to_zoom = std::clamp(zoom, 0, 6);
}

// Camera::check_zoom @00843c30, run every 33 ms of the graphic clock: zoom one level toward to_zoom_level; pan by
// max(0x300, distance / 2) per axis toward the target, snapping once within 0x300 on both axes (scroll_lock_flags & 8
// blocks the moves).
- (void)cameraStep:(double)dtMs {
	_camAccumMs += dtMs;
	const ron::sim::ScriptPresentation* p = [self pres];
	const bool locked = p && (p->scroll_lock_flags & 8);
	while (_camAccumMs >= 33.0) {
		_camAccumMs -= 33.0;
		if (_pan.zooming) {
			if (_zoom < _pan.to_zoom) _zoom++;
			else if (_zoom > _pan.to_zoom) _zoom--;
			else _pan.zooming = false;
		}
		if (_pan.panning) {
			const int lx = int(_lookAt.x), ly = int(_lookAt.y);
			const int dx = _pan.to_x - lx, dy = _pan.to_y - ly;
			if (std::abs(dx) < 0x300 && std::abs(dy) < 0x300) {
				if (!locked) [self lookAtX:float(_pan.to_x) y:float(_pan.to_y)];
				_pan.panning = 0;
				continue;
			}
			const int sx = std::max(0x300, std::abs(dx) / 2), sy = std::max(0x300, std::abs(dy) / 2);
			const int nx = std::abs(dx) < 0x300 ? lx : lx + (dx > 0 ? sx : -sx);
			const int ny = std::abs(dy) < 0x300 ? ly : ly + (dy > 0 ? sy : -sy);
			if (!locked) [self lookAtX:float(std::clamp(nx, 0, int(_mesh.width))) y:float(std::clamp(ny, 0, int(_mesh.height)))];
		}
	}
}

// popup_dialog / popup_choice: in a window, a nested event loop draws the popup and waits for a button (the script is
// suspended inside Game::do_frame, as in BasePop::exec); headless runs answer button 0.
- (int)runPopup:(const ron::sim::ScriptEvent&)e {
	std::printf("script popup: \"%s\"\n", e.text.c_str());
	if (_headless && _sviewOn && getenv("RON_POPUP_KEEP")) _sview.open_popup(e);  // snapshot check of the popup's look
	if (!_sviewOn || _headless || !self.view.window) return 0;
	_sview.open_popup(e);
	_inPopup = YES;
	_popupResult = -1;
	while (_popupResult < 0 && self.view.window.isVisible) {
		@autoreleasepool {
			NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / 60]
			                                    inMode:NSDefaultRunLoopMode dequeue:YES];
			if (ev) [NSApp sendEvent:ev];
			[self.view draw];
		}
	}
	_inPopup = NO;
	_sview.close_popup();
	return std::max(0, _popupResult);
}

// Mouse on the modal windows (popup buttons, the goal dialog's OK). Returns YES when consumed.
- (BOOL)modalMouse:(CGPoint)p up:(BOOL)up {
	if (_sview.popup_open()) {
		const int b = _sview.popup_button_at(int(p.x), int(p.y));
		if (!up) _sview.popup().pressed = b;
		else if (b >= 0 && b == _sview.popup().pressed) _popupResult = b;
		if (up) _sview.popup().pressed = -1;
		return YES;
	}
	if (_sview.goal_dialog_open()) {
		if (up && _sview.goal_dialog_close_at(int(p.x), int(p.y))) _sview.close_goal_dialog();
		return YES;
	}
	return NO;
}

// ScenarioData::draw_components @00997920: each add_flag is the ScenarioFlag piece (first_flag_piece + 2) at the tile
// centre on the terrain, scale (3, -3, 3), angle 45, leader 0's colour, its "Banner Wave" clock offset by the position
// ((frame + y * 17 + x * 13) % frames) * 67 ms. The banner is single-sided: with this matrix (the units' mirrored
// basis) it faces the camera only with the cull mode left unflipped (checked by snapshot; the units flip).
- (void)encodeFlags:(id<MTLRenderCommandEncoder>)enc {
	const ron::sim::ScriptPresentation* p = [self pres];
	if (!p || p->flags.empty()) return;
	const int team = _game && !_game->leaders.empty() ? std::clamp(_game->leaders[0].color, 0, 8) : 0;
	const uint8_t* tc = kUnitTeamColors[team];
	const simd_float4 tint = simd_make_float4(tc[0], tc[1], tc[2], 255) / 255.0f;
	const float s = 3, a = 45 * float(M_PI) / 180.0f, c = std::cos(a), sn = std::sin(a);
	const char* piece = "ScenarioFlag";
	for (const auto& f : p->flags) {
		const float x = float(f[0] * 192 + 96), y = float(f[1] * 192 + 96);
		const float z = std::max(0.0f, _terrain.sample_height(x, y));
		const simd_float4x4 world = simd_matrix(simd_make_float4(c * s, sn * s, 0, 0), simd_make_float4(sn * s, -c * s, 0, 0),
		                                        simd_make_float4(0, 0, s, 0), simd_make_float4(x, y, z, 1));
		const double ms = double((_game ? _game->frame : 0) + int(y) * 17 + int(x) * 13) * 67.0;
		if (!_units.draw_ammo(enc, piece, ms, world, false, tint)) {
			static bool warned = false;
			if (!warned) std::fprintf(stderr, "flag: the ScenarioFlag piece has no model\n"), warned = true;
		}
	}
}

// MessageWin::add_event's ANNOUNCE_CIRCLE: a TRANSPARENT_WHITE ring on the terrain shrinking over 8 ticks.
- (void)encodeAnnounce:(id<MTLRenderCommandEncoder>)enc {
	if (!_sviewOn || _sview.announces().empty()) return;
	static const ron::RenderState& circle_rs = *ron::find_render_state("Circle Blend");
	std::vector<ron::ColorVertex> verts;
	std::vector<uint32_t> idx;
	const int kSeg = 48, tick = int(_timeMs / 66.0);
	for (const scriptview::View::Announce& an : _sview.announces()) {
		const float r1 = 192.0f * float(8 - std::clamp(tick - an.tick, 0, 7)), r0 = r1 - 40;
		const uint32_t base = uint32_t(verts.size());
		for (int k = 0; k <= kSeg; k++) {
			const float a = float(k) / kSeg * 2 * float(M_PI), c = std::cos(a), s = std::sin(a);
			for (float r : {std::max(0.0f, r0), r1}) {
				const float x = an.x + c * r, y = an.y + s * r;
				verts.push_back({x, y, std::max(0.0f, _terrain.sample_height(x, y)) + 4, 0, 0, 1, 0, 0, 255, 255, 255, 64});
			}
		}
		for (uint32_t k = 0; k < uint32_t(kSeg); k++) {
			const uint32_t a = base + k * 2;
			idx.insert(idx.end(), {a, a + 1, a + 2, a + 2, a + 1, a + 3});
		}
	}
	rm::DrawUniforms du = rm::draw_uniforms(circle_rs, matrix_identity_float4x4);
	_overlayStates.bind(enc, circle_rs, rm::VertexKind::Colored);
	[enc setCullMode:MTLCullModeNone];
	id<MTLBuffer> vb = [_device newBufferWithBytes:verts.data() length:verts.size() * sizeof(ron::ColorVertex) options:MTLResourceStorageModeShared];
	id<MTLBuffer> ib = [_device newBufferWithBytes:idx.data() length:idx.size() * 4 options:MTLResourceStorageModeShared];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentBytes:&du length:sizeof du atIndex:1];
	[enc setFragmentTexture:_white atIndex:0];
	[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:idx.size() indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0];
}

// ---------------------------------------------------------------- cursors (docs/ui-spec.md 7)

- (NSCursor*)cursorWithId:(int)cid {
	auto it = _cursors.find(cid);
	if (it != _cursors.end()) return it->second;
	return _cursors[cid] = ron_game_cursor(*_files, cid);
}

// The context cursor (Console::execute_at_cursor preview): Move To while targeting, Attack over an enemy with own units
// selected, else Main.
- (NSCursor*)cursorAt:(CGPoint)p {
	int cid = ron::kCursorMain;
	if (!([self hudVisible] && _hud.captures(int(p.x), int(p.y))) && _game) {
		if (_targeting == hud::kOptMoveTo) {
			cid = ron::kCursorMoveTo;
		} else if (!_selected.empty() && _placeType < 0) {
			int32_t who = -1, o = -1, type = -1;
			const int me = [self localPlayer];
			if ([self pickAt:p who:who o:o type:type] && who != me && ron::sim::is_enemy(*_game, me, who)) cid = ron::kCursorAttack;
		}
	}
	return [self cursorWithId:cid];
}

@end

// The game window's view: events go to the front end while it is up, else to the game.
@interface MapView : MTKView
@property(nonatomic, weak) MapRenderer* renderer;
@property(nonatomic, weak) FrontEnd* frontEnd;
@end

@implementation MapView {
	NSTrackingArea* _tracking;
}
- (BOOL)acceptsFirstResponder {
	return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
	return YES;
}
- (void)keyDown:(NSEvent*)event {
	if (self.frontEnd) {
		[self.frontEnd keyDown:event];
		return;
	}
	[self.renderer scriptKey:event down:YES];
	[self.renderer handleKey:event];
}
- (void)keyUp:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer scriptKey:event down:NO];
}
- (void)flagsChanged:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer scriptFlags:event.modifierFlags];
}
- (void)mouseEntered:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer setMouseInside:YES];
}
- (void)mouseExited:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer setMouseInside:NO];
}
// Events go to the renderer in UI pixels: view points with a top-left origin (the HUD's coordinate space).
- (CGPoint)uiPoint:(NSEvent*)event {
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	return CGPointMake(p.x, self.bounds.size.height - p.y);
}
- (NSCursor*)cursorAt:(CGPoint)p {
	if (self.frontEnd) return [self.frontEnd cursor];
	if (self.renderer) return [self.renderer cursorAt:p];
	return [NSCursor arrowCursor];
}
- (void)updateTrackingAreas {
	[super updateTrackingAreas];
	if (_tracking) [self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
	                                         options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingCursorUpdate
	                                           owner:self
	                                        userInfo:nil];
	[self addTrackingArea:_tracking];
}
- (void)cursorUpdate:(NSEvent*)event {
	[[self cursorAt:[self uiPoint:event]] set];
}
- (void)mouseMoved:(NSEvent*)event {
	const CGPoint p = [self uiPoint:event];
	if (self.frontEnd) [self.frontEnd mouseMoved:p];
	else [self.renderer uiMouseMoved:p];
	[[self cursorAt:p] set];
}
- (void)mouseDown:(NSEvent*)event {
	if (self.frontEnd) [self.frontEnd mouseDown:[self uiPoint:event] clicks:event.clickCount];
	else [self.renderer uiMouseDown:[self uiPoint:event] right:NO modifiers:event.modifierFlags clicks:event.clickCount];
}
- (void)mouseDragged:(NSEvent*)event {
	if (self.frontEnd) [self.frontEnd mouseDragged:[self uiPoint:event]];
	else [self.renderer uiMouseDragged:[self uiPoint:event] right:NO delta:CGPointMake(event.deltaX, event.deltaY)];
}
- (void)mouseUp:(NSEvent*)event {
	if (self.frontEnd) [self.frontEnd mouseUp:[self uiPoint:event]];
	else [self.renderer uiMouseUp:[self uiPoint:event] right:NO modifiers:event.modifierFlags];
	[[self cursorAt:[self uiPoint:event]] set];
}
- (void)rightMouseDown:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer uiMouseDown:[self uiPoint:event] right:YES modifiers:event.modifierFlags clicks:event.clickCount];
}
- (void)rightMouseDragged:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer uiMouseDragged:[self uiPoint:event] right:YES delta:CGPointMake(event.deltaX, event.deltaY)];
}
- (void)rightMouseUp:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer uiMouseUp:[self uiPoint:event] right:YES modifiers:event.modifierFlags];
}
- (void)scrollWheel:(NSEvent*)event {
	if (self.frontEnd) {
		const CGFloat dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24.0 : event.scrollingDeltaY;
		[self.frontEnd scrollWheel:dy at:[self uiPoint:event]];
		return;
	}
	[self.renderer uiScrollWheel:event at:[self uiPoint:event]];
}
- (void)magnifyWithEvent:(NSEvent*)event {
	if (!self.frontEnd) [self.renderer uiMagnify:float(event.magnification) at:[self uiPoint:event]];
}
@end

// The app: one window whose view shows either the front end or a game; Play and Return to Main Menu swap them in place.
@interface MapAppDelegate : NSObject <NSApplicationDelegate, FrontEndHost>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) MapView* view;
@property(nonatomic, strong) MapRenderer* renderer;  // the running game (nil while the menu is up)
@property(nonatomic, strong) FrontEnd* menu;         // the front end (nil during a game)
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, copy) NSString* gameDir;
@property(nonatomic, copy) NSString* startScreen;
@end

@implementation MapAppDelegate
// Everything is created once the app has finished launching, inside [NSApp run]: a window ordered front (or a modal
// session run) before that is torn down during launch, and the app then quits as its last window closed.
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
	// Come to the front even when started from Finder, `open` or a terminal (macOS 14 restricts activateIgnoringOtherApps).
	if (@available(macOS 14.0, *)) [NSApp activate];
	else [NSApp activateIgnoringOtherApps:YES];
	if (!self.renderer) {
		NSString* dir = self.gameDir;
		if (!launcher::looks_like_install(dir)) dir = launcher::saved_or_guessed_install();
		if (!launcher::looks_like_install(dir)) dir = launcher::ask_for_install(nil);
		if (!dir) {
			[NSApp terminate:nil];
			return;
		}
		launcher::remember_install(dir);
		self.gameDir = dir;
	}
	NSRect frame = NSMakeRect(0, 0, 1440, 900);
	if (NSScreen* screen = NSScreen.mainScreen) {
		const NSRect vis = screen.visibleFrame;
		frame.size.width = std::min<CGFloat>(frame.size.width, std::floor(vis.size.width * 0.92));
		frame.size.height = std::min<CGFloat>(frame.size.height, std::floor(vis.size.height * 0.92));
	}
	self.window = [[NSWindow alloc] initWithContentRect:frame
	                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                    NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
	                                            backing:NSBackingStoreBuffered
	                                              defer:NO];
	self.window.releasedWhenClosed = NO;
	self.window.title = @"OpenRiseOfNations";
	self.window.contentMinSize = NSMakeSize(640, 480);
	self.view = [[MapView alloc] initWithFrame:frame device:self.device];
	self.view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	self.view.framebufferOnly = YES;
	self.window.contentView = self.view;
	if (self.renderer) {
		[self attachGame:self.renderer];
	} else if (![self showMenu:self.startScreen]) {
		[NSApp terminate:nil];
		return;
	}
	[self.window center];
	[self.window makeKeyAndOrderFront:nil];
	[self.window makeFirstResponder:self.view];
	if (@available(macOS 14.0, *)) [NSApp activate];
	else [NSApp activateIgnoringOtherApps:YES];
	[self.window orderFrontRegardless];
	if (getenv("RON_FLOW_TEST")) [self flowTest:0];
}

// Debugging aid (RON_FLOW_TEST=1): menu -> Play (tutorial 1) -> game menu "Return to Main Menu" -> Play (skirmish) ->
// back -> quit, a few seconds apart, printing each step: checks the in-window swaps without clicking.
- (void)flowTest:(int)step {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		std::printf("flow test step %d: %s\n", step, self.renderer ? "game" : self.menu ? "menu" : "?");
		std::fflush(stdout);
		switch (step) {
			case 0: [self frontEndPlay:@"scenario/Tutorial1/tut1.scx" difficulty:-1]; break;
			case 1: [self.renderer openGameMenu:1]; break;
			case 2: if (self.renderer.onExit) self.renderer.onExit(NO); break;
			case 3: [self frontEndPlay:@"scenario/Custom/skirmish/skirmish.scx" difficulty:3]; break;
			case 4: if (self.renderer.onExit) self.renderer.onExit(NO); break;
			default: [NSApp terminate:nil]; return;
		}
		[self flowTest:step + 1];
	});
}

- (void)alert:(NSString*)title text:(NSString*)text {
	NSAlert* a = [NSAlert new];
	a.messageText = title;
	a.informativeText = text ?: @"Unknown error";
	[a runModal];
}

// The front end in the window (screen nil: the one remembered from last time).
- (BOOL)showMenu:(NSString*)screen {
	if (!self.menu) {
		NSString* err = nil;
		self.menu = [[FrontEnd alloc] initWithDevice:self.device gameDir:self.gameDir error:&err];
		if (!self.menu) {
			[self alert:@"Could not open the menu" text:err];
			return NO;
		}
	}
	FrontEnd* m = self.menu;
	self.view.renderer = nil;
	self.view.frontEnd = m;
	self.view.delegate = m;
	m.view = self.view;
	m.host = self;
	self.renderer = nil;  // the game (its sounds stop with it)
	[m startInteractive];
	[m showScreen:screen ?: ([NSUserDefaults.standardUserDefaults stringForKey:launcher::kDefScreen] ?: @"main")];
	self.window.title = @"OpenRiseOfNations";
	[self.window makeFirstResponder:self.view];
	[[m cursor] set];
	return YES;
}

- (void)attachGame:(MapRenderer*)r {
	self.renderer = r;
	r.view = self.view;
	self.view.frontEnd = nil;
	self.view.renderer = r;
	self.view.delegate = r;
	__weak MapAppDelegate* weakSelf = self;
	// Swapped on the next turn of the run loop: the game's own event handler is still on the stack.
	r.onExit = ^(BOOL quit) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (quit) [NSApp terminate:nil];
			else [weakSelf showMenu:nil];
		});
	};
	[r updateTitle];
	[r startInteractive];
	[self.window makeFirstResponder:self.view];
}

- (void)frontEndConfigureSkirmish:(NSString*)scenario difficulty:(int)difficulty {
	ron::sim::SkirmishSetup setup;
	NSString* error = nil;
	if (!choose_skirmish_setup(self.gameDir, scenario, difficulty, setup, &error)) {
		if (error) [self.menu showError:error];
		return;
	}
	g_skirmish = setup;
	[self startFrontEndMatch:scenario difficulty:setup.difficulty];
}

- (void)frontEndPlay:(NSString*)scenario difficulty:(int)difficulty {
	g_skirmish.reset();
	[self startFrontEndMatch:scenario difficulty:difficulty];
}

- (void)startFrontEndMatch:(NSString*)scenario difficulty:(int)difficulty {
	[self.menu setBusy:@"Loading…"];
	[self.view draw];
	dispatch_async(dispatch_get_main_queue(), ^{
		g_difficulty = difficulty;
		NSString* err = nil;
		MapRenderer* r = [[MapRenderer alloc] initWithDevice:self.device gameDir:self.gameDir scenario:scenario simulate:YES seed:12345 error:&err];
		g_skirmish.reset();
		if (!r) {
			[self.menu setBusy:nil];
			[self.menu showError:[NSString stringWithFormat:@"Could not load the scenario: %@", err ?: @"unknown error"]];
			return;
		}
		const CGSize ds = self.view.drawableSize;
		const float scale = float(self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1);
		[r setUiWidth:int(ds.width) height:int(ds.height) scale:scale];
		[self.menu stopAudio];
		self.view.frontEnd = nil;
		self.menu = nil;  // its backdrop textures are large; the menu is rebuilt on the way back
		[self attachGame:r];
	});
}

- (void)frontEndChangeFolder {
	NSString* dir = launcher::choose_install(self.gameDir);
	if (!dir || [dir isEqualToString:self.gameDir]) return;
	NSString* err = nil;
	FrontEnd* m = [[FrontEnd alloc] initWithDevice:self.device gameDir:dir error:&err];
	if (!m) {
		[self alert:@"Could not open the menu" text:err];
		return;
	}
	launcher::remember_install(dir);
	self.gameDir = dir;
	[self.menu stopAudio];
	self.menu = m;
	[self showMenu:@"main"];
}

- (void)frontEndQuit {
	[NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
	return YES;
}
@end

static MapAppDelegate* g_delegate;  // the app delegate property is weak; keep it alive for the whole run

static void run_app(MapAppDelegate* d) {
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy:NSApplicationActivationPolicyRegular];
	NSMenu* menuBar = [NSMenu new];
	NSMenuItem* appItem = [NSMenuItem new];
	[menuBar addItem:appItem];
	NSMenu* appMenu = [NSMenu new];
	[appMenu addItemWithTitle:@"Quit OpenRiseOfNations" action:@selector(terminate:) keyEquivalent:@"q"];
	appItem.submenu = appMenu;
	app.mainMenu = menuBar;
	g_delegate = d;
	app.delegate = d;
	[app run];
}

int main(int argc, const char* argv[]) {
	@autoreleasepool {
		NSString* gameDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Games/RiseOfNations"];
		NSString* scenario = nil;
		NSString* snapshot = nil;
		int zoom = -1, w = 1600, h = 1000;
		float atX = NAN, atY = NAN;
		bool bloom = true, select_all = false, simulate = true, fog = true, hud_on = true;
		float ui_scale = 1;
		int sel_who = -1, build_page = -1, place_type = -1, play = -1;
		bool place_click = false, script_log = false;
		struct TimedSelect {
			int who = 0, frame = 0;
			bool builds = false;
			std::vector<int32_t> objs;
		};
		std::vector<TimedSelect> timed_selects;
		struct TimedOption {
			int option = -1, menu = -1, type = -1, frame = 0;
		};
		std::vector<TimedOption> timed_options;
		struct TimedCursor {
			float x = 0, y = 0;
			int frame = 0;
		};
		std::vector<TimedCursor> timed_cursors, timed_looks;
		struct TimedZoom {
			int level = 5, frame = 0;
		};
		std::vector<TimedZoom> timed_zooms;
		struct QueueArg {
			int who = 0, o = 0, type = 0, n = 1;
		};
		std::vector<QueueArg> queues;
		bool sel_builds = false;
		std::vector<int32_t> sel_objs;
		float place_x = 0, place_y = 0;
		uint32_t seed = 12345;
		int sim_frames = 0;
		struct MoveArg {
			int who = 0, frame = 0;
			std::vector<int32_t> objs;
			int32_t x = 0, y = 0;
		};
		std::vector<MoveArg> moves;
		struct AttackArg {
			int who = 0, frame = 0, twho = 0, to = 0;
			std::vector<int32_t> objs;
		};
		std::vector<AttackArg> attacks;
		float farm_time = 0;
		struct BuildArg {
			std::string name;
			float x, y;
			int team;
		};
		std::vector<BuildArg> builds;
		std::vector<BuildArg> units;  // name, x, y, angle in `team`
		std::vector<NSString*> positional;
		bool menu = false;
		NSString* menuScreen = nil;
		for (int i = 1; i < argc; i++) {
			const std::string a = argv[i];
			const bool more = i + 1 < argc;
			if (a == "--zoom" && more) {
				zoom = std::atoi(argv[++i]);
			} else if (a == "--at" && more) {
				std::sscanf(argv[++i], "%f,%f", &atX, &atY);
			} else if (a == "--snapshot" && more) {
				snapshot = @(argv[++i]);
			} else if (a == "--size" && more) {
				std::sscanf(argv[++i], "%dx%d", &w, &h);
			} else if (a == "--build" && more) {
				// NAME@X,Y[@TEAM]
				const std::string spec = argv[++i];
				const size_t at = spec.find('@');
				BuildArg b{spec.substr(0, at), 0, 0, 1};
				if (at != std::string::npos) std::sscanf(spec.c_str() + at + 1, "%f,%f@%d", &b.x, &b.y, &b.team);
				builds.push_back(b);
			} else if (a == "--unit" && more) {
				// NAME@X,Y[@ANGLE]
				const std::string spec = argv[++i];
				const size_t at = spec.find('@');
				BuildArg u{spec.substr(0, at), 0, 0, 0};
				if (at != std::string::npos) std::sscanf(spec.c_str() + at + 1, "%f,%f@%d", &u.x, &u.y, &u.team);
				units.push_back(u);
			} else if (a == "--farm-time" && more) {
				farm_time = float(std::atof(argv[++i]));
			} else if (a == "--select-all") {
				select_all = true;
			} else if (a == "--no-sim") {
				simulate = false;
			} else if (a == "--seed" && more) {
				seed = uint32_t(std::strtoul(argv[++i], nullptr, 0));
			} else if (a == "--frames" && more) {
				sim_frames = std::atoi(argv[++i]);
			} else if (a == "--move" && more) {
				// WHO:o1,o2,...@X,Y[@FRAME]
				const std::string spec = argv[++i];
				MoveArg m;
				const size_t colon = spec.find(':'), at = spec.find('@');
				if (colon == std::string::npos || at == std::string::npos || at < colon) {
					std::fprintf(stderr, "bad --move %s (WHO:o1,o2@X,Y[@FRAME])\n", spec.c_str());
					return 2;
				}
				m.who = std::atoi(spec.c_str());
				for (size_t p = colon + 1; p < at;) {
					m.objs.push_back(int32_t(std::strtol(spec.c_str() + p, nullptr, 0)));
					const size_t comma = spec.find(',', p);
					if (comma == std::string::npos || comma > at) break;
					p = comma + 1;
				}
				std::sscanf(spec.c_str() + at + 1, "%d,%d@%d", &m.x, &m.y, &m.frame);
				moves.push_back(m);
			} else if (a == "--attack" && more) {
				// WHO:o1,o2,...@TWHO:TO[@FRAME]
				const std::string spec = argv[++i];
				AttackArg k;
				const size_t colon = spec.find(':'), at = spec.find('@');
				if (colon == std::string::npos || at == std::string::npos || at < colon) {
					std::fprintf(stderr, "bad --attack %s (WHO:o1,o2@TWHO:TO[@FRAME])\n", spec.c_str());
					return 2;
				}
				k.who = std::atoi(spec.c_str());
				for (size_t p = colon + 1; p < at;) {
					k.objs.push_back(int32_t(std::strtol(spec.c_str() + p, nullptr, 0)));
					const size_t comma = spec.find(',', p);
					if (comma == std::string::npos || comma > at) break;
					p = comma + 1;
				}
				std::sscanf(spec.c_str() + at + 1, "%d:%d@%d", &k.twho, &k.to, &k.frame);
				attacks.push_back(k);
			} else if (a == "--no-hud") {
				hud_on = false;
			} else if (a == "--ui-scale" && more) {
				ui_scale = float(std::atof(argv[++i]));
			} else if ((a == "--select" || a == "--select-build") && more && std::strchr(argv[i + 1], '@')) {
				// WHO:o1,o2,...@FRAME: a selection made at FRAME (the scripts see it from then on)
				const std::string spec = argv[++i];
				TimedSelect t;
				t.builds = a == "--select-build";
				t.who = std::atoi(spec.c_str());
				const size_t colon = spec.find(':'), at = spec.find('@');
				for (size_t q = colon == std::string::npos ? at : colon + 1; q < at;) {
					t.objs.push_back(int32_t(std::strtol(spec.c_str() + q, nullptr, 0)));
					const size_t comma = spec.find(',', q);
					if (comma == std::string::npos || comma > at) break;
					q = comma + 1;
				}
				t.frame = std::atoi(spec.c_str() + at + 1);
				timed_selects.push_back(t);
			} else if (a == "--option" && more) {
				// N[:MENU[:TYPE]]@FRAME
				const std::string spec = argv[++i];
				TimedOption t;
				const size_t at = spec.find('@');
				std::sscanf(spec.c_str(), "%d:%d:%d", &t.option, &t.menu, &t.type);
				if (at != std::string::npos) t.frame = std::atoi(spec.c_str() + at + 1);
				timed_options.push_back(t);
			} else if (a == "--cursor" && more) {
				TimedCursor t;
				std::sscanf(argv[++i], "%f,%f@%d", &t.x, &t.y, &t.frame);
				timed_cursors.push_back(t);
			} else if (a == "--look" && more) {  // X,Y@FRAME: the player scrolls the camera there
				TimedCursor t;
				std::sscanf(argv[++i], "%f,%f@%d", &t.x, &t.y, &t.frame);
				timed_looks.push_back(t);
			} else if (a == "--zoom-at" && more) {  // LEVEL@FRAME: the player zooms
				TimedZoom t;
				std::sscanf(argv[++i], "%d@%d", &t.level, &t.frame);
				timed_zooms.push_back(t);
			} else if (a == "--script-log") {
				script_log = true;
			} else if ((a == "--select" || a == "--select-build") && more) {
				// WHO:o1,o2,...
				const std::string spec = argv[++i];
				sel_builds = a == "--select-build";
				sel_who = std::atoi(spec.c_str());
				const size_t colon = spec.find(':');
				for (size_t q = colon == std::string::npos ? spec.size() : colon + 1; q < spec.size();) {
					sel_objs.push_back(int32_t(std::strtol(spec.c_str() + q, nullptr, 0)));
					const size_t comma = spec.find(',', q);
					if (comma == std::string::npos) break;
					q = comma + 1;
				}
			} else if (a == "--place-click") {
				place_click = true;
			} else if (a == "--queue" && more) {
				// WHO:O@TYPE[*N]  a building trains / researches TYPE (QUEUE_UP), as the card's buttons do
				QueueArg q;
				std::sscanf(argv[++i], "%d:%d@%d*%d", &q.who, &q.o, &q.type, &q.n);
				queues.push_back(q);
			} else if (a == "--play" && more) {
				play = std::atoi(argv[++i]);
			} else if (a == "--build-page" && more) {
				build_page = std::atoi(argv[++i]);
			} else if (a == "--place" && more) {
				std::sscanf(argv[++i], "%d@%f,%f", &place_type, &place_x, &place_y);
			} else if (a == "--difficulty" && more) {
				g_difficulty = std::atoi(argv[++i]);
			} else if (a == "--no-fog") {
				fog = false;
			} else if (a == "--no-bloom") {
				bloom = false;
			} else if (a == "--menu") {
				menu = true;
				static const char* const screens[] = {"main", "tutorials", "skirmish", "scenarios", "quit-popup"};
				for (const char* sname : screens) {
					if (more && std::strcmp(argv[i + 1], sname) == 0) menuScreen = @(argv[++i]);
				}
			} else if (a.rfind("--", 0) == 0) {
				std::printf("usage: %s [game-dir] [--menu [main|tutorials|skirmish|scenarios|quit-popup]] [--snapshot out.png [--size WxH]]\n"
				            "       %s [game-dir] <scenario.scx> [--zoom 0..6] [--at X,Y] [--no-bloom] [--farm-time S] [--no-sim] [--seed S] "
				            "[--move WHO:o1,o2@X,Y[@FRAME]]... [--frames N] [--snapshot out.png [--size WxH]]\n", argv[0], argv[0]);
				return a == "--help" ? 0 : 2;
			} else {
				if (a.rfind("-psn_", 0) != 0) positional.push_back(@(argv[i]));  // Finder's process serial number
			}
		}
		if (positional.size() == 2) gameDir = positional[0], scenario = positional[1];
		NSString* explicitDir = positional.size() == 2 ? positional[0] : nil;
		if (positional.size() == 1) {
			// One argument: a game folder opens the menu, anything else is a scenario.
			if (launcher::looks_like_install(positional[0])) explicitDir = gameDir = positional[0];
			else scenario = positional[0];
		}
		if (!scenario) menu = true;
		if (menu) {
			// The front end: headless with --snapshot, else the app opens its window on the Main Menu.
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
			if (!device) {
				std::fprintf(stderr, "no Metal device\n");
				return 1;
			}
			if (snapshot) {
				NSString* dir = launcher::looks_like_install(explicitDir) ? explicitDir : launcher::saved_or_guessed_install();
				NSString* error = nil;
				FrontEnd* fe = [[FrontEnd alloc] initWithDevice:device gameDir:dir error:&error];
				if (!fe) {
					std::fprintf(stderr, "%s\n", (error ?: @"no Rise of Nations install found").UTF8String);
					return 1;
				}
				[fe showScreen:menuScreen ?: @"main"];
				return [fe snapshotTo:snapshot width:w height:h scale:ui_scale] ? 0 : 1;
			}
			MapAppDelegate* d = [MapAppDelegate new];
			d.device = device;
			d.gameDir = explicitDir;
			d.startScreen = menuScreen;
			run_app(d);
			return 0;
		}
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device) {
			std::fprintf(stderr, "no Metal device\n");
			return 1;
		}
		NSString* error = nil;
		MapRenderer* r = [[MapRenderer alloc] initWithDevice:device gameDir:gameDir scenario:scenario simulate:simulate seed:seed error:&error];
		if (!r) {
			std::fprintf(stderr, "%s\n", error.UTF8String);
			return 1;
		}
		if (zoom >= 0) r.zoom = zoom;
		if (!std::isnan(atX)) [r lookAtX:atX y:atY];
		r.bloom = bloom;
		r.fogOn = fog;
		if (farm_time > 0) [r advanceFarmsTo:uint32_t(farm_time * 15.0f)];
		for (const BuildArg& b : builds) [r placeBuilding:b.name x:b.x y:b.y team:b.team];
		for (const BuildArg& u : units) [r placeUnit:u.name x:u.x y:u.y angle:float(u.team) team:1];
		r.hudOn = r.hudOn && hud_on;
		[r setUiWidth:w height:h scale:ui_scale];  // the UI the scripts query before any frame is drawn
		[r setScriptLog:script_log];
		if (const char* t = getenv("RON_POPUP_TEST")) [r testPopup:t];
		if (const char* t = getenv("RON_GAME_MENU")) [r openGameMenu:std::atoi(t)];  // 1 the game menu, 2 game over
		if (play >= 0) [r setLocalPlayer:play];
		if (sel_who >= 0) [r selectWho:sel_who objects:sel_objs buildings:sel_builds];
		if (build_page >= 0) [r setBuildPage:build_page];
		if (place_type >= 0) {
			[r startPlacement:place_type];
			[r previewPlacementAtWorldX:place_x y:place_y];
		}
		if (place_type >= 0 && place_click) [r placeAtWorldX:place_x y:place_y modifiers:0];
		for (const QueueArg& q : queues) [r queueWho:q.who building:q.o type:q.type count:q.n];
		// Scripted moves, then N simulation frames (headless checks with --snapshot).
		for (int f = 0; f <= sim_frames && r.simulating; f++) {
			for (const MoveArg& m : moves) {
				if (m.frame == f && ![r issueMoveWho:m.who objects:m.objs x:m.x y:m.y])
					std::fprintf(stderr, "--move for leader %d issued nothing\n", m.who);
			}
			for (const AttackArg& k : attacks) {
				if (k.frame == f && ![r issueAttackWho:k.who objects:k.objs targetWho:k.twho target:k.to])
					std::fprintf(stderr, "--attack for leader %d issued nothing\n", k.who);
			}
			for (const TimedSelect& t : timed_selects) {
				if (t.frame == f) [r selectWho:t.who objects:t.objs buildings:t.builds];
			}
			for (const TimedOption& t : timed_options) {
				if (t.frame != f) continue;
				// As the card runs it: the option's button, then the page and the building button.
				[r runCardOption:(t.option < 0 ? hud::kOptCancel : t.option) object:-1];
				if (t.menu >= 0) [r setBuildPage:t.menu];
				if (t.type >= 0) [r runCardOption:1000 object:t.type];
			}
			for (const TimedCursor& t : timed_cursors) {
				if (t.frame == f) [r setCursorWorldX:t.x y:t.y];
			}
			for (const TimedCursor& t : timed_looks) {
				if (t.frame == f) [r lookAtX:t.x y:t.y];
			}
			for (const TimedZoom& t : timed_zooms) {
				if (t.frame == f) r.zoom = t.level;
			}
			if (f < sim_frames) [r stepSimulation:1];
		}
		if (select_all) [r selectAll];
		if (snapshot) return [r snapshotTo:snapshot width:w height:h scale:ui_scale] ? 0 : 1;

		MapAppDelegate* d = [MapAppDelegate new];
		d.device = device;
		d.renderer = r;
		d.gameDir = gameDir;
		run_app(d);
	}
	return 0;
}
