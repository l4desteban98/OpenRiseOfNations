#include "sim/skirmish.hpp"
#include "sim/game.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>
using namespace ron;
using namespace ron::sim;

Scenario fixture() {
    Scenario m;
    m.name = "Synthetic test map";
    m.scenario_flags = 1 | 4;
    m.game_rules = 10;
    m.victory = 7;
    m.time_limit = 3;
    m.terrain.xs = 48;
    for (int who : {1, 3, 6}) {
        ScenarioPlayer p;
        p.who = who; p.tribe = who; p.is_human = who == 3 ? 4 : 0;
        p.leader_flags = 0x400;
        p.techs = {"preserved tech"};
        p.child_order = {38, 41, 44};
        p.stockpile = {{0, 123}};
        m.players.push_back(p);
        ScenarioUnit u; u.who = who; m.units.push_back(u);
        ScenarioBuilding b; b.who = who; b.city = true; m.buildings.push_back(b);
    }
    ScenarioUnit gaia; gaia.who = 9; m.units.push_back(gaia);
    return m;
}
void rejected(const Scenario& original, const SkirmishSetup& s) {
    Scenario m = original;
    bool caught = false;
    try { configure_skirmish(m, s, 24); } catch (const std::invalid_argument&) { caught = true; }
    assert(caught);
    assert(m.players.size() == original.players.size() && m.units.size() == original.units.size());
    assert(m.scenario_flags == original.scenario_flags && m.game_rules == original.game_rules);
}
int main() {
    const auto original = fixture();
    auto s = default_skirmish(original, 4);
    assert(s.human == 3 && s.difficulty == 4);
    assert(s.seats[1].enabled && !s.seats[0].enabled);
    auto bad = s; bad.seats[0].enabled = true; rejected(original, bad);
    bad = s; bad.seats[3].enabled = false; rejected(original, bad);
    bad = s; bad.seats[1].enabled = bad.seats[6].enabled = false; rejected(original, bad);
    bad = s; for (int i : {1,3,6}) bad.seats[i].team = 0; rejected(original, bad);
    bad = s; bad.seats[1].tribe = 24; rejected(original, bad);
    bad = s; bad.seats[1].team = 4; rejected(original, bad);
    bad = s; bad.difficulty = 6; rejected(original, bad);
    bad = s; bad.reveal = 4; rejected(original, bad);
    bad = s; bad.resources = -2; rejected(original, bad);

    auto map = original;
    s.seats[1].enabled = false;
    s.seats[3].tribe = 12;
    s.human = 6;
    s.resources = 500;
    s.reveal = 3;
    configure_skirmish(map, s, 24);
    assert(map.players.size() == 2 && map.player(1) == nullptr);
    assert(map.player(3)->tribe == 12 && map.player(3)->is_human == 0 && map.player(6)->is_human == 4);
    assert(map.units.size() == 3 && map.units.back().who == 9 && map.buildings.size() == 2);
    assert(map.terrain.xs == 48 && map.player(3)->techs == original.player(3)->techs);
    assert(map.scenario_flags == 4 && map.game_rules == 0 && map.victory == 2 && map.time_limit == 0);
    for (const auto& p : map.players) {
        assert(!(p.leader_flags & 0x400));
        assert(p.stockpile.size() == 6);
        for (const auto& st : p.stockpile) assert(st.amount == 500);
        for (const auto& d : p.diplomacy) assert(d.diplo == (d.who == p.who ? 2 : 0));
    }
    GameInfo info;
    configure_skirmish_info(info, s);
    assert(info.num_players == 2 && info.num_nations == 2 && info.num_sides == 2);
    assert(info.difficulty == 4 && info.reveal_map == 3 && info.team[1] == -1);

    map = original; s = default_skirmish(map, 2);
    s.seats[1].team = s.seats[3].team = 0;
    s.seats[6].team = 1;
    s.conquest = false;
    configure_skirmish(map, s, 24);
    configure_skirmish_info(info, s);
    assert(info.num_nations == 3 && info.num_sides == 2 && info.team[6] == 1);
    assert(map.player(1)->diplomacy[1].diplo == 2 && map.player(1)->diplomacy[2].diplo == 0);
    assert(map.victory == 7 && map.time_limit == 3);
    assert(map.player(1)->stockpile[0].amount == 123);
    std::cout << "Skirmish configuration tests passed\n";
}
