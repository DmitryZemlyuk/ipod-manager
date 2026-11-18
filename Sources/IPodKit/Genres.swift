import Foundation

/// Turns MusicBrainz tags (free-form, voted by users) into a genre.
/// Tags also contain things like "british" or "seen live", so only names from this list count.
enum Genres {
    static let known: Set<String> = [
        // pop
        "pop", "dance-pop", "synth-pop", "electropop", "indie pop", "art pop", "dream pop", "power pop", "pop rock",
        "pop punk", "pop rap", "teen pop", "k-pop", "j-pop", "c-pop", "europop", "bubblegum pop", "baroque pop",
        "chamber pop", "sophisti-pop", "hyperpop", "bedroom pop", "latin pop", "britpop", "city pop", "schlager",
        "chanson", "adult contemporary", "easy listening", "new wave", "disco", "nu-disco", "italo-disco", "euro-disco",
        "eurodance", "boy band", "singer-songwriter", "soft rock",
        // rock
        "rock", "alternative rock", "indie rock", "hard rock", "classic rock", "progressive rock", "psychedelic rock",
        "punk rock", "punk", "post-punk", "garage rock", "glam rock", "folk rock", "blues rock", "southern rock",
        "art rock", "space rock", "stoner rock", "surf rock", "rock and roll", "rockabilly", "grunge", "post-grunge",
        "shoegaze", "noise rock", "math rock", "post-rock", "emo", "screamo", "post-hardcore", "hardcore punk",
        "melodic hardcore", "skate punk", "ska punk", "ska", "new romantic", "gothic rock", "darkwave", "krautrock",
        "experimental rock", "symphonic rock", "arena rock", "heartland rock", "roots rock", "jangle pop", "madchester",
        "funk rock", "rap rock", "nu metal", "alternative metal", "industrial rock", "russian rock", "electronic rock",
        "dance-rock", "post-britpop", "indie", "alternative", "lo-fi", "garage punk", "horror punk", "pub rock",
        // metal
        "metal", "heavy metal", "thrash metal", "death metal", "black metal", "doom metal", "power metal",
        "progressive metal", "symphonic metal", "gothic metal", "folk metal", "melodic death metal", "metalcore",
        "deathcore", "groove metal", "speed metal", "glam metal", "industrial metal", "sludge metal", "stoner metal",
        "post-metal", "djent", "grindcore", "viking metal", "pagan metal",
        // electronic
        "electronic", "electronica", "house", "deep house", "progressive house", "tech house", "electro house",
        "acid house", "future house", "tropical house", "big room house", "french house", "funky house", "garage house",
        "techno", "minimal techno", "detroit techno", "hard techno", "acid techno", "trance", "progressive trance",
        "uplifting trance", "vocal trance", "psytrance", "goa trance", "tech trance", "hard trance", "drum and bass",
        "liquid funk", "jungle", "neurofunk", "dubstep", "brostep", "future bass", "trap", "edm", "electro",
        "electroclash", "breakbeat", "big beat", "uk garage", "2-step", "grime", "ambient", "dark ambient", "downtempo",
        "trip hop", "trip-hop", "chillout", "chillwave", "vaporwave", "synthwave", "idm", "glitch", "industrial", "ebm",
        "hardcore", "hardstyle", "gabber", "happy hardcore", "eurobeat", "dance", "club", "bass music", "footwork",
        "minimal", "microhouse", "lounge", "new age", "electro-industrial", "futurepop", "witch house", "moombahton",
        "complextro", "melodic techno", "melodic house", "organic house", "afro house", "slap house", "phonk",
        "drumstep", "midtempo bass", "wave", "dance-punk", "indietronica", "folktronica",
        // hip hop / r&b
        "hip hop", "hip-hop", "rap", "gangsta rap", "trap rap", "conscious hip hop", "alternative hip hop",
        "east coast hip hop", "west coast hip hop", "southern hip hop", "boom bap", "cloud rap", "emo rap", "drill",
        "crunk", "horrorcore", "instrumental hip hop", "abstract hip hop", "russian hip hop", "r&b", "contemporary r&b",
        "alternative r&b", "soul", "neo soul", "funk", "motown", "new jack swing", "quiet storm", "gospel", "doo-wop",
        // jazz / blues / folk / country
        "jazz", "smooth jazz", "acid jazz", "jazz fusion", "bebop", "swing", "big band", "cool jazz", "free jazz",
        "vocal jazz", "nu jazz", "bossa nova", "blues", "electric blues", "delta blues", "rhythm and blues", "folk",
        "indie folk", "contemporary folk", "folk pop", "neofolk", "celtic", "americana", "bluegrass", "country",
        "country pop", "country rock", "alternative country", "outlaw country", "world", "worldbeat", "bard",
        // latin / reggae / other
        "latin", "reggaeton", "salsa", "bachata", "merengue", "cumbia", "tango", "flamenco", "samba", "mpb",
        "reggae", "dub", "dancehall", "roots reggae", "afrobeat", "afrobeats", "amapiano", "highlife",
        "classical", "opera", "baroque", "romantic", "contemporary classical", "modern classical", "minimalism",
        "neoclassical", "orchestral", "choral", "soundtrack", "film score", "video game music", "musical", "score",
        "anime", "children's music", "christmas music", "comedy", "spoken word", "audiobook", "experimental",
        "avant-garde", "noise", "drone", "instrumental", "a cappella", "acoustic", "turbo-folk", "pop-folk", "chalga"
    ]

    /// Tags that are listed only to be normalised to another spelling.
    static let aliases: [String: String] = ["hip-hop": "hip hop", "trip-hop": "trip hop"]

    /// The best-voted tag that is a genre, nicely capitalised ("Trip Hop", "Dance-pop").
    static func pick(_ tags: [MBGenre]?) -> String? {
        var best: (name: String, count: Int)?
        for t in tags ?? [] {
            let raw = t.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard known.contains(raw) else { continue }
            let count = t.count ?? 0
            guard count > 0 else { continue }
            if best == nil || count > best!.count { best = (aliases[raw] ?? raw, count) }
        }
        guard let name = best?.name else { return nil }
        let upper: Set<String> = ["edm", "idm", "ebm", "mpb", "r&b", "uk"]
        return name.split(separator: " ").map { w -> String in
            upper.contains(String(w)) ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
