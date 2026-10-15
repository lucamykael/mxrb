package mxrb.sidecar;

import java.util.Map;

import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;

/** An association of the application's metamodel. */
public final class MxMetaAssociation implements IMetaAssociation {
	private final Metadata metadata;
	private final String name;
	private final String parent;
	private final String child;
	private final AssociationType type;
	private final AssociationOwner owner;

	MxMetaAssociation(Metadata metadata, Map<String, Object> definition) {
		this.metadata = metadata;
		this.name = (String) definition.get("name");
		this.parent = (String) definition.get("parent");
		this.child = (String) definition.get("child");
		this.type = AssociationType.valueOf((String) definition.get("type"));
		this.owner = AssociationOwner.valueOf((String) definition.get("owner"));
	}

	String parentName() {
		return parent;
	}

	String childName() {
		return child;
	}

	@Override
	public String getName() {
		return name;
	}

	@Override
	public MxMetaObject getChild() {
		return metadata.object(child);
	}

	@Override
	public AssociationOwner getOwner() {
		return owner;
	}

	@Override
	public MxMetaObject getParent() {
		return metadata.object(parent);
	}

	@Override
	public AssociationType getType() {
		return type;
	}

	@Override
	public String toString() {
		return name;
	}
}
