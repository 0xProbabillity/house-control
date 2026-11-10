#if ROOM_SCAN
import RoomPlan
import simd
import HouseCore

// RoomPlan's results in the plain numbers of `RoomScan`, which `ScanLayout` turns into a plan.
// A surface's or an object's own x axis (the transform's first column) runs along its width.

extension RoomScan.Point {
    init(_ v: simd_float3) { self.init(x: Double(v.x), y: Double(v.y), z: Double(v.z)) }
    init(_ v: simd_float4) { self.init(x: Double(v.x), y: Double(v.y), z: Double(v.z)) }
}

extension RoomScan.Room {
    init(_ room: CapturedRoom) {
        func surfaces(_ list: [CapturedRoom.Surface], _ kind: RoomScan.SurfaceKind) -> [RoomScan.Surface] {
            list.map { s in
                let t = s.transform
                return RoomScan.Surface(kind: kind, center: RoomScan.Point(t.columns.3),
                                        axisX: Double(t.columns.0.x), axisZ: Double(t.columns.0.z),
                                        width: Double(s.dimensions.x), height: Double(s.dimensions.y))
            }
        }
        let objects = room.objects.filter { $0.confidence != .low }.compactMap { object -> RoomScan.Object? in
            guard let category = Self.category(object.category) else { return nil }
            let t = object.transform
            return RoomScan.Object(category: category, kind: Self.kind(of: object), center: RoomScan.Point(t.columns.3),
                                   axisX: Double(t.columns.0.x), axisZ: Double(t.columns.0.z),
                                   width: Double(object.dimensions.x), height: Double(object.dimensions.y),
                                   depth: Double(object.dimensions.z))
        }
        let floor = room.floors.flatMap { surface in
            surface.polygonCorners.map { RoomScan.Point(surface.transform * simd_float4($0, 1)) }
        }
        self.init(walls: surfaces(room.walls, .wall),
                  openings: surfaces(room.doors, .door) + surfaces(room.windows, .window) + surfaces(room.openings, .opening),
                  objects: objects,
                  sections: room.sections.map { RoomScan.Section(label: $0.label.rawValue, center: RoomScan.Point($0.center)) },
                  floor: floor)
    }

    private static func category(_ category: CapturedRoom.Object.Category) -> String? {
        switch category {
        case .storage: "storage"
        case .refrigerator: "refrigerator"
        case .stove: "stove"
        case .bed: "bed"
        case .sink: "sink"
        case .washerDryer: "washerDryer"
        case .toilet: "toilet"
        case .bathtub: "bathtub"
        case .oven: "oven"
        case .dishwasher: "dishwasher"
        case .table: "table"
        case .sofa: "sofa"
        case .chair: "chair"
        case .fireplace: "fireplace"
        case .television: "television"
        case .stairs: "stairs"
        @unknown default: nil
        }
    }

    /// What kind of table, chair or storage it is, where RoomPlan could tell.
    private static func kind(of object: CapturedRoom.Object) -> String? {
        if let table = object.attribute(of: TableType.self) {
            switch table {
            case .coffee: return "coffee"
            case .dining: return "dining"
            default: return nil
            }
        }
        if let storage = object.attribute(of: StorageType.self) {
            switch storage {
            case .shelf: return "shelf"
            case .cabinet: return "cabinet"
            @unknown default: return nil
            }
        }
        if let chair = object.attribute(of: ChairType.self) {
            switch chair {
            case .dining: return "dining"
            case .stool: return "stool"
            case .swivel: return "swivel"
            default: return nil
            }
        }
        return nil
    }
}
#endif
