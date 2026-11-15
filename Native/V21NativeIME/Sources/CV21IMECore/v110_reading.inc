// Included inside V21Resources. Preserve only the two resource-registered
// primary readings; this is not an exhaustive/polyphonic Cartesian fallback.
std::array<int32_t,8192> sourceDefaults;
bool standalonePrimaryReading(uint16_t character,uint16_t syllable)const {
 if(character>=defaults.size()||syllable>=legal.size())return false;
 if(defaults[character]!=syllable&&sourceDefaults[character]!=syllable)return false;
 return std::binary_search(legal[syllable].begin(),legal[syllable].end(),character);
}
