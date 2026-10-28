#pragma once
#import <Cocoa/Cocoa.h>
#include "sim/skirmish.hpp"
// Native setup dialog for the map selected in the Skirmish list. Cancel leaves the menu unchanged.
bool choose_skirmish_setup(NSString* gameDir, NSString* scenario, int difficulty, ron::sim::SkirmishSetup& result, NSString** error);
