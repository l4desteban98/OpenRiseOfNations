// Custom matches on existing scenario terrain. No install files are modified.
#pragma once
#include <array>
#include "assets/scenario.hpp"

namespace ron::sim {
struct GameInfo;
struct SkirmishSeat {
    bool enabled = false;
    int tribe = 0;
    int team = -1; // -1 free-for-all; 0..3 teams
};
struct SkirmishSetup {
    std::array<SkirmishSeat, 8> seats{};
    int human = 0;
    int difficulty = 2;
    int reveal = 1;
    int resources = -1; // -1 preserve map; otherwise each of the six stockpiles
    bool conquest = true;
};
SkirmishSetup default_skirmish(const Scenario& map, int difficulty);
// Validates before mutating. Only existing map slots can be enabled. Throws invalid_argument.
void configure_skirmish(Scenario& map, const SkirmishSetup& setup, int tribe_count);
void configure_skirmish_info(GameInfo& info, const SkirmishSetup& setup);
} // namespace ron::sim
