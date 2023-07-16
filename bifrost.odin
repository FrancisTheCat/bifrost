package bifrost

import "core:mem"
import "core:fmt"

MAX_ENTITIES :: 10_000
MAX_COMPONENTS :: 64

ComponentsBitSet :: bit_set[0 ..< MAX_COMPONENTS]

EntityID :: u64
EntityIndex :: u32
EntityVersion :: u32

INVALID_ENTITY: EntityID : u64(0xff_ff_ff_ff_00_00_00_00)

Error :: enum {
	InvalidEntity,
	InvalidComponent,
	EntityDoesNotHaveComponent,
}

Ecs :: struct {
	// These are pointers to component pools, bc they are polymorphic we have to store them as rawptrs
	components:     [MAX_COMPONENTS]ComponentPool,
	// this holds the actual types of the components and is needed to access the components
	component_list: map[typeid]int,
	components_num: int,
	// this should be a small array or smth like that
	entities:       [MAX_ENTITIES]Entity,
	entities_len:   int,
	free_entities:  [dynamic]EntityIndex,
}

ecs: Ecs

@(private = "file")
Entity :: struct {
	id:   EntityID,
	mask: ComponentsBitSet,
}

@(private = "file")
ComponentPool :: struct {
	data: rawptr,
	type: typeid,
}

@(private = "file")
get_component_pool :: proc($T: typeid) -> ComponentPool {
	return ecs.components[ecs.component_list[T]]
}

get_component :: proc(entity: EntityID, $T: typeid) -> (component: ^T, error: Error) {
	if ecs.entities[get_entity_index(entity)].id != entity {
		return nil, .InvalidEntity
	}
	entity := &ecs.entities[get_entity_index(entity)]
	if !(ecs.component_list[T] in entity.mask) {
		return nil, .InvalidComponent
	}

	pool := get_component_pool(T)
	ptr := mem.ptr_offset(transmute(^T)pool.data, get_entity_index(entity.id))
	return ptr, nil
}

has_component :: proc(entity: EntityID, Component: typeid) -> bool {
	if ecs.entities[get_entity_index(entity)].id != entity do return false
	entity := ecs.entities[get_entity_index(entity)]
	return ecs.component_list[Component] in entity.mask
}

has_components :: proc(
	entity: EntityID,
	components: ..typeid,
) -> (
	has_components: bool,
	error: Error,
) {
	if ecs.entities[get_entity_index(entity)].id != entity do return false, .InvalidEntity
	for c in components {
		has_c := has_component(entity, c)
		if !has_c do return false, nil
	}
	return true, nil
}

get_component_id :: proc(T: typeid) -> (int, Error) {
	if !(T in ecs.component_list) do return -1, .InvalidComponent
	return ecs.component_list[T], nil
}

add_component :: proc(entity: EntityID, component: $T, location := #caller_location) -> Error {
	e := &ecs.entities[get_entity_index(entity)]
	if e.id != entity do return .InvalidEntity

	component_id, component_exists := ecs.component_list[T]
	assert(component_exists, fmt.tprint("tried to add component that did not exist\n", location))
	e.mask += {component_id}
	c_ptr, component_err := get_component(entity, T)
	if component_err != nil do return component_err
	c_ptr^ = component
	return nil
}

remove_component :: proc(entity: EntityID, $T: typeid) -> Error {
	entity := &ecs.entities[get_entity_index(entity)]
	if entity.id != entity do return .InvalidEntity
	entity.mask -= {get_component_id(T)}
	return nil
}

new_entity :: proc() -> EntityID {
	if len(ecs.free_entities) != 0 {
		new_index := ecs.free_entities[len(ecs.free_entities) - 1]
		pop(&ecs.free_entities)
		new_id := create_entity_id(new_index, get_entity_version(ecs.entities[new_index].id))
		e := Entity {
			id = new_id,
		}
		ecs.entities[new_index] = e
		return new_id
	}
	e := Entity {
		id = create_entity_id(u32(ecs.entities_len), 0),
	}
	ecs.entities[ecs.entities_len] = e
	ecs.entities_len += 1
	return e.id
}

destroy_entity :: proc(entity: EntityID) -> Error {
	if ecs.entities[get_entity_index(entity)].id != entity do return .InvalidEntity
	entity_destruction_callback(entity)
	new_id := create_entity_id(transmute(u32)i32(-1), get_entity_version(entity) + 1)
	ecs.entities[get_entity_index(entity)].id = new_id
	ecs.entities[get_entity_index(entity)].mask = {}
	append(&ecs.free_entities, get_entity_index(entity))
	return nil
}

@(private = "file")
create_entity_id :: proc(index: EntityIndex, version: EntityVersion) -> EntityID {
	return EntityID(index) << 32 | EntityID(version)
}

@(private = "file")
get_entity_index :: proc(entity_id: EntityID) -> EntityIndex {
	return EntityIndex(entity_id >> 32)
}

@(private = "file")
get_entity_version :: proc(entity_id: EntityID) -> EntityVersion {
	return EntityVersion(entity_id)
}

is_entity_valid :: proc(entity_id: EntityID) -> bool {
	if get_entity_index(entity_id) == transmute(u32)i32(-1) do return false
	entity := ecs.entities[get_entity_index(entity_id)]
	if get_entity_index(entity.id) == transmute(u32)i32(-1) do return false
	return true
}

init_component :: proc($T: typeid) {
	c: ComponentPool
	c.data = new([MAX_ENTITIES * size_of(T)]byte)
	c.type = T
	ecs.components[ecs.components_num] = c
	ecs.component_list[T] = ecs.components_num
	ecs.components_num += 1
}

EntitiesIter :: struct {
	index:               EntityIndex,
	required_components: ComponentsBitSet,
}

make_entity_iter :: proc {
	make_entity_iter_var,
	make_entity_iter_all,
}

make_entity_iter_var :: proc(components: ..typeid) -> (iter: EntitiesIter, error: Error) {
	for component in components {
		id, err := get_component_id(component)
		if err != nil {
			error = .InvalidComponent
			return
		}
		iter.required_components += {id}
	}
	return
}

make_entity_iter_all :: proc() -> EntitiesIter {
	return EntitiesIter{}
}

entities_iter :: proc(iter: ^EntitiesIter) -> (val: EntityID, idx: EntityIndex, cond: bool) {
	for {
		if cond = iter.index < auto_cast ecs.entities_len; cond {
			e := &ecs.entities[iter.index]
			idx = iter.index
			iter.index += 1
			if e.mask >= iter.required_components &&
			   ecs.entities[get_entity_index(e.id)].id == e.id {
				val = e.id
				break
			}
		} else {
			iter.index = 0
			break
		}
	}
	return
}

entity_destruction_callback := proc(e: EntityID) {}

uninit :: proc() {
	for i in 0 ..< ecs.components_num {
		pool := ecs.components[i]
		free(pool.data)
	}
	delete(ecs.free_entities)
	delete(ecs.component_list)
}

set_component :: proc(e: EntityID, component: $T) {
	c, _ := get_component(e, T)
	c^ = component
}
