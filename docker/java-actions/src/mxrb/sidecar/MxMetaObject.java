package mxrb.sidecar;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;
import com.mendix.systemwideinterfaces.core.meta.IMetaObject;
import com.mendix.systemwideinterfaces.core.meta.IMetaPrimitive;

/** An entity of the application's metamodel. */
public final class MxMetaObject implements IMetaObject {
	private final Metadata metadata;
	private final String name;
	private final String module;
	private final boolean persistable;
	private final List<String> supers;
	private final List<String> subs;
	private final List<MxMetaPrimitive> primitives = new ArrayList<>();

	@SuppressWarnings("unchecked")
	MxMetaObject(Metadata metadata, Map<String, Object> definition) {
		this.metadata = metadata;
		this.name = (String) definition.get("name");
		this.module = (String) definition.get("module");
		this.persistable = Boolean.TRUE.equals(definition.get("persistable"));
		this.supers = (List<String>) (List<?>) definition.get("supers");
		this.subs = (List<String>) (List<?>) definition.get("subs");
		for (Object primitive : (List<Object>) definition.get("primitives")) {
			primitives.add(new MxMetaPrimitive(metadata, this, (Map<String, Object>) primitive));
		}
	}

	@Override
	public String getModuleName() {
		return module;
	}

	@Override
	public String getName() {
		return name;
	}

	/** The direct generalization: of the supers, the one with the most supers itself. */
	@Override
	public String getSuperName() {
		MxMetaObject parent = getSuperObject();
		return parent == null ? null : parent.getName();
	}

	@Override
	public MxMetaObject getSuperObject() {
		MxMetaObject parent = null;
		for (MxMetaObject candidate : getSuperObjects()) {
			if (parent == null || candidate.supers.size() > parent.supers.size()) {
				parent = candidate;
			}
		}
		return parent;
	}

	@Override
	public List<MxMetaObject> getSuperObjects() {
		return objects(supers);
	}

	@Override
	public List<MxMetaObject> getSubObjects() {
		return objects(subs);
	}

	@Override
	public boolean isSubClassOf(String other) {
		return name.equals(other) || supers.contains(other);
	}

	@Override
	public Boolean isPersistable() {
		return persistable;
	}

	@Override
	public boolean hasCreatedDateAttr() {
		return getMetaPrimitive("createdDate") != null;
	}

	@Override
	public boolean hasChangedDateAttr() {
		return getMetaPrimitive("changedDate") != null;
	}

	@Override
	public boolean hasOwnerAttr() {
		return getMetaAssociationParent("System.owner") != null;
	}

	@Override
	public boolean hasChangedByAttr() {
		return getMetaAssociationParent("System.changedBy") != null;
	}

	@Override
	public Collection<MxMetaPrimitive> getMetaPrimitives() {
		return new ArrayList<>(primitives);
	}

	@Override
	public MxMetaPrimitive getMetaPrimitive(String member) {
		for (MxMetaPrimitive primitive : primitives) {
			if (primitive.getName().equals(member)) {
				return primitive;
			}
		}
		return null;
	}

	/** The attributes the entity declares itself, not those of its generalizations. */
	@Override
	public Collection<MxMetaPrimitive> getDeclaredMetaPrimitives() {
		MxMetaObject parent = getSuperObject();
		List<MxMetaPrimitive> declared = new ArrayList<>();
		for (MxMetaPrimitive primitive : primitives) {
			if (parent == null || parent.getMetaPrimitive(primitive.getName()) == null) {
				declared.add(primitive);
			}
		}
		return declared;
	}

	@Override
	public Collection<MxMetaPrimitive> getNonVirtualDeclaredMetaPrimitives() {
		List<MxMetaPrimitive> declared = new ArrayList<>(getDeclaredMetaPrimitives());
		declared.removeIf(MxMetaPrimitive::isVirtual);
		return declared;
	}

	@Override
	public MxMetaPrimitive getDeclaredMetaPrimitive(String member) {
		for (MxMetaPrimitive primitive : getDeclaredMetaPrimitives()) {
			if (primitive.getName().equals(member)) {
				return primitive;
			}
		}
		return null;
	}

	@Override
	public Collection<IMetaAssociation> getMetaAssociationsChild() {
		return associations(false, false);
	}

	@Override
	public IMetaAssociation getMetaAssociationChild(String association) {
		return find(getMetaAssociationsChild(), association);
	}

	/** The associations the entity or one of its generalizations owns. */
	@Override
	public Collection<IMetaAssociation> getMetaAssociationsParent() {
		return associations(true, false);
	}

	@Override
	public IMetaAssociation getMetaAssociationParent(String association) {
		return find(getMetaAssociationsParent(), association);
	}

	@Override
	public Collection<IMetaAssociation> getDeclaredMetaAssociationsChild() {
		return associations(false, true);
	}

	@Override
	public IMetaAssociation getDeclaredMetaAssociationChild(String association) {
		return find(getDeclaredMetaAssociationsChild(), association);
	}

	@Override
	public Collection<IMetaAssociation> getDeclaredMetaAssociationsParent() {
		return associations(true, true);
	}

	@Override
	public IMetaAssociation getDeclaredMetaAssociationParent(String association) {
		return find(getDeclaredMetaAssociationsParent(), association);
	}

	@Override
	public boolean isUser() {
		return isSubClassOf("System.User");
	}

	@Override
	public boolean isFileDocument() {
		return isSubClassOf("System.FileDocument");
	}

	@Override
	public String toString() {
		return name;
	}

	private List<MxMetaObject> objects(List<String> names) {
		List<MxMetaObject> result = new ArrayList<>();
		for (String entity : names) {
			MxMetaObject object = metadata.object(entity);
			if (object != null) {
				result.add(object);
			}
		}
		return result;
	}

	private Collection<IMetaAssociation> associations(boolean parent, boolean declared) {
		List<IMetaAssociation> result = new ArrayList<>();
		for (MxMetaAssociation association : metadata.associations()) {
			String end = parent ? association.parentName() : association.childName();
			if (declared ? end.equals(name) : isSubClassOf(end)) {
				result.add(association);
			}
		}
		return result;
	}

	private static IMetaAssociation find(Collection<IMetaAssociation> associations, String name) {
		for (IMetaAssociation association : associations) {
			if (association.getName().equals(name)) {
				return association;
			}
		}
		return null;
	}
}
