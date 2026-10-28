#import "skirmish_setup.h"
#include "assets/files.hpp"
#include "sim/rules.hpp"
#include <exception>
#include <vector>

namespace {
NSTextField* label(NSView* view, NSString* text, CGFloat x, CGFloat y, CGFloat width) {
    NSTextField* field = [NSTextField wrappingLabelWithString:text];
    field.frame = NSMakeRect(x, y, width, 24);
    [view addSubview:field];
    return field;
}
NSPopUpButton* popup(NSView* view, NSArray<NSString*>* titles, CGFloat x, CGFloat y, CGFloat width) {
    NSPopUpButton* button = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y, width, 26) pullsDown:NO];
    [button addItemsWithTitles:titles];
    [view addSubview:button];
    return button;
}
}

bool choose_skirmish_setup(NSString* dir, NSString* scenario, int difficulty, ron::sim::SkirmishSetup& result, NSString** error) {
    try {
        ron::GameFiles files(dir.UTF8String);
        std::string path = scenario.UTF8String;
        const auto resolved = files.resolve(path);
        if (!resolved.empty()) path = resolved;
        const ron::Scenario map = ron::parse_scenario(ron::read_file(path));
        const auto rules = ron::sim::load_rules(files);
        auto setup = ron::sim::default_skirmish(map, difficulty);
        NSMutableArray<NSString*>* nations = [NSMutableArray array];
        for (const auto& tribe : rules.tribes) {
            const std::string name = ron::sim::to_utf8(tribe.eng_name.empty() ? tribe.name : tribe.eng_name);
            [nations addObject:name.empty() ? [NSString stringWithFormat:@"Nation %lu", (unsigned long)nations.count + 1] : @(name.c_str())];
        }
        std::vector<int> seats;
        for (int i = 0; i < 8; ++i) if (map.player(i)) seats.push_back(i);
        if (seats.size() < 2 || nations.count == 0) {
            *error = @"This map needs at least two existing player positions and a valid civilization list.";
            return false;
        }
        const CGFloat height = 220 + seats.size() * 34;
        NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, height)];
        label(content, @"Position", 0, height - 24, 80);
        label(content, @"Control", 90, height - 24, 120);
        label(content, @"Civilization", 220, height - 24, 230);
        label(content, @"Team", 460, height - 24, 155);
        NSMutableArray<NSPopUpButton*>* controls = [NSMutableArray array];
        NSMutableArray<NSPopUpButton*>* civs = [NSMutableArray array];
        NSMutableArray<NSPopUpButton*>* teams = [NSMutableArray array];
        for (size_t row = 0; row < seats.size(); ++row) {
            const int who = seats[row];
            const CGFloat y = height - 62 - row * 34;
            label(content, [NSString stringWithFormat:@"Player %d", who + 1], 0, y, 85);
            auto control = popup(content, @[@"Closed", @"Human", @"Computer"], 90, y, 120);
            [control selectItemAtIndex:who == setup.human ? 1 : 2];
            auto civ = popup(content, nations, 220, y, 230);
            if (setup.seats[size_t(who)].tribe >= 0 && setup.seats[size_t(who)].tribe < int(nations.count))
                [civ selectItemAtIndex:setup.seats[size_t(who)].tribe];
            auto team = popup(content, @[@"No team", @"Team 1", @"Team 2", @"Team 3", @"Team 4"], 460, y, 155);
            [controls addObject:control]; [civs addObject:civ]; [teams addObject:team];
        }
        label(content, @"AI difficulty", 0, 142, 100);
        auto diff = popup(content, @[@"Easiest", @"Easy", @"Moderate", @"Tough", @"Tougher", @"Toughest"], 110, 142, 170);
        [diff selectItemAtIndex:setup.difficulty];
        label(content, @"Visibility", 315, 142, 85);
        auto fog = popup(content, @[@"Normal", @"Explored", @"All visible"], 410, 142, 205);
        label(content, @"Resources", 0, 104, 100);
        auto resources = popup(content, @[@"Map stockpiles", @"500 of each", @"2000 of each"], 110, 104, 170);
        label(content, @"Victory", 315, 104, 85);
        auto victory = popup(content, @[@"Conquest", @"Map victory settings"], 410, 104, 205);
        NSTextField* note = label(content, @"Uses this map's starting positions, armies, buildings and technologies. Closed positions are removed. Scenario scripts are disabled. Map size and random terrain are not available yet.", 0, 12, 615);
        note.frame = NSMakeRect(0, 12, 615, 72);
        NSAlert* dialog = [[NSAlert alloc] init];
        dialog.messageText = @"Custom Skirmish";
        dialog.informativeText = [NSString stringWithFormat:@"Map: %@ — select exactly one human and at least one opposing computer.", @(map.name.c_str())];
        dialog.accessoryView = content;
        [dialog addButtonWithTitle:@"Start Match"];
        [dialog addButtonWithTitle:@"Cancel"];
        while ([dialog runModal] == NSAlertFirstButtonReturn) {
            int humans = 0;
            for (size_t row = 0; row < seats.size(); ++row) {
                int who = seats[row];
                auto& seat = setup.seats[size_t(who)];
                seat.enabled = controls[row].indexOfSelectedItem != 0;
                seat.tribe = int(civs[row].indexOfSelectedItem);
                seat.team = int(teams[row].indexOfSelectedItem) - 1;
                if (controls[row].indexOfSelectedItem == 1) { ++humans; setup.human = who; }
            }
            setup.difficulty = int(diff.indexOfSelectedItem);
            setup.reveal = int(fog.indexOfSelectedItem) + 1;
            setup.resources = resources.indexOfSelectedItem == 0 ? -1 : resources.indexOfSelectedItem == 1 ? 500 : 2000;
            setup.conquest = victory.indexOfSelectedItem == 0;
            try {
                if (humans != 1) throw std::invalid_argument("Select exactly one human player.");
                auto check = map;
                ron::sim::configure_skirmish(check, setup, int(rules.tribes.size()));
                result = setup;
                return true;
            } catch (const std::exception& e) {
                NSAlert* invalid = [[NSAlert alloc] init];
                invalid.messageText = @"Check match settings";
                invalid.informativeText = @(e.what());
                [invalid runModal];
            }
        }
        return false;
    } catch (const std::exception& e) {
        *error = @(e.what());
        return false;
    }
}
