#include "sim/skirmish.hpp"
#include "sim/game.hpp"
#include <algorithm>
#include <set>
#include <stdexcept>

namespace ron::sim {
SkirmishSetup default_skirmish(const Scenario& map, int difficulty) {
    SkirmishSetup s;
    s.difficulty = std::clamp(difficulty, 0, 5);
    s.human = -1;
    for (const auto& p : map.players) {
        if (p.who < 0 || p.who >= 8) continue;
        s.seats[size_t(p.who)] = {true, p.tribe, -1};
        if (s.human < 0 && p.is_human) s.human = p.who;
    }
    if (s.human < 0) for (int i = 0; i < 8; ++i)
        if (s.seats[size_t(i)].enabled) { s.human = i; break; }
    return s;
}

void configure_skirmish(Scenario& map, const SkirmishSetup& s, int tribe_count) {
    auto fail = [](const char* message) { throw std::invalid_argument(message); };
    if (s.human < 0 || s.human >= 8 || !s.seats[size_t(s.human)].enabled)
        fail("Choose an enabled human player.");
    if (s.difficulty < 0 || s.difficulty > 5 || s.reveal < 0 || s.reveal > 3 || s.resources < -1 || s.resources > 100000)
        fail("Invalid match settings.");
    int count = 0;
    bool opponent = false;
    const int human_team = s.seats[size_t(s.human)].team;
    std::set<int> slots;
    for (const auto& p : map.players) {
        if (p.who >= 0 && p.who < 8 && !slots.insert(p.who).second) fail("Duplicate player slot in map.");
    }
    for (int i = 0; i < 8; ++i) {
        const auto& seat = s.seats[size_t(i)];
        if (!seat.enabled) continue;
        if (!map.player(i)) fail("This map has no starting position for that player.");
        if (seat.tribe < 0 || seat.tribe >= tribe_count || seat.team < -1 || seat.team > 3)
            fail("Invalid civilization or team.");
        ++count;
        if (i != s.human && (human_team < 0 || seat.team != human_team)) opponent = true;
    }
    if (count < 2 || !opponent) fail("Enable at least one opposing computer player.");

    // Retain slot identities: cities, camera positions and object references use them.
    auto closed = [&](int who) { return who >= 0 && who < 8 && !s.seats[size_t(who)].enabled; };
    map.players.erase(std::remove_if(map.players.begin(), map.players.end(), [&](const auto& p) { return closed(p.who); }), map.players.end());
    map.units.erase(std::remove_if(map.units.begin(), map.units.end(), [&](const auto& u) {
        return closed(u.who) || (u.inside >= 0 && closed(u.inside_who));
    }), map.units.end());
    map.buildings.erase(std::remove_if(map.buildings.begin(), map.buildings.end(), [&](const auto& b) { return closed(b.who); }), map.buildings.end());
    for (auto& p : map.players) {
        if (p.who < 0 || p.who >= 8) continue;
        p.tribe = s.seats[size_t(p.who)].tribe;
        p.is_human = p.who == s.human ? 4 : 0;
        p.leader_flags &= ~0x400u; // no scenario co-op control
        p.difficulty = s.difficulty;
        p.diplomacy.clear();
        p.has_diplomacy = true;
        for (int i = 0; i < 8; ++i) if (s.seats[size_t(i)].enabled) {
            const bool ally = i == p.who || (s.seats[size_t(p.who)].team >= 0 && s.seats[size_t(p.who)].team == s.seats[size_t(i)].team);
            p.diplomacy.push_back({i, ally ? 2 : 0, ally ? 1 : 0});
        }
        // Always apply our diplomacy after any imported child chunks.
        p.child_order.erase(std::remove(p.child_order.begin(), p.child_order.end(), 41), p.child_order.end());
        p.child_order.push_back(41);
        if (s.resources >= 0) {
            p.stockpile.clear();
            for (int good = 0; good < 6; ++good) p.stockpile.push_back({good, s.resources});
            p.child_order.erase(std::remove(p.child_order.begin(), p.child_order.end(), 44), p.child_order.end());
            p.child_order.push_back(44);
        }
    }
    // Custom matches retain terrain and armies, but not scenario objectives/triggers.
    map.scenario_flags &= ~1u;
    map.has_settings = true;
    map.game_rules = 0;
    map.team_style = 1;
    map.reveal_map = s.reveal;
    if (s.conquest) {
        map.victory = 2; // conquest
        map.elimination = 0; // all cities lost
        map.score_goal = map.time_limit = map.wonderwin = map.popwin = map.econwin = 0;
    }
}

void configure_skirmish_info(GameInfo& info, const SkirmishSetup& s) {
    info.difficulty = uint8_t(s.difficulty);
    info.reveal_map = uint8_t(s.reveal);
    info.num_players = info.num_nations = info.num_sides = 0;
    info.team.fill(-1);
    std::set<int> teams;
    for (int i = 0; i < 8; ++i) if (s.seats[size_t(i)].enabled) {
        ++info.num_players;
        ++info.num_nations;
        const int team = s.seats[size_t(i)].team;
        info.team[size_t(i)] = int8_t(team);
        if (team < 0) ++info.num_sides;
        else teams.insert(team);
    }
    info.num_sides += int(teams.size());
}
} // namespace ron::sim
