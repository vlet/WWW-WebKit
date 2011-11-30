package WWW::WebKit;

use 5.10.0;
use Moose;

use Gtk3;
use Gtk3::WebKit;
use Glib qw(TRUE FALSE);
use Time::HiRes qw(time usleep);
use X11::Xlib;

use constant DOM_TYPE_ELEMENT => 1;
use constant ORDERED_NODE_SNAPSHOT_TYPE => 7;

has xvfb => (
    is  => 'ro',
    isa => 'Bool',
);

has view => (
    is      => 'ro',
    isa     => 'Gtk3::WebKit::WebView',
    lazy    => 1,
    default => sub {
        Gtk3::WebKit::WebView->new
    },
);

has window => (
    is      => 'ro',
    isa     => 'Gtk3::Window',
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        my $sw = Gtk3::ScrolledWindow->new;
        $sw->add($self->view);

        my $win = Gtk3::Window->new;
        $win->set_default_size(800, 600);
        $win->add($sw);
        return $win;
    }
);

has alerts => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has console_messages => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has default_timeout => (
    is      => 'rw',
    isa     => 'Int',
    default => 30_000,
);

has xvfb_pid => (
    is  => 'rw',
    isa => 'Int',
);

has xvfb_server => (
    is => 'rw',
);

sub init {
    my ($self) = @_;

    $self->setup_xvfb if $self->xvfb;

    Gtk3::init;

    $self->view->signal_connect('script-alert' => sub {
        warn 'alert: ' . $_[2];
        push @{ $self->alerts }, $_[2];
    });
    $self->view->signal_connect('console-message' => sub {
        warn "console: $_[1] at line $_[2] in $_[3], user_data: $_[4]";
        push @{ $self->console_messages }, $_[1];
        return FALSE;
    });

    $self->window->show_all;
    Gtk3->main_iteration while Gtk3->events_pending;

    return $self;
}

sub setup_xvfb {
    my ($self) = @_;

    my ($server, $display);
    while (1) {
        $display = 1 + int(rand(98));

        last if $self->xvfb_pid(open $server, '|-', "Xvfb :$display -screen 0 800x600x24 2>/dev/null");
    }
    sleep 1;
    $self->xvfb_server($server);
    $ENV{DISPLAY} = ":$display";
}

sub DESTROY {
    my ($self) = @_;
    return unless $self->xvfb_pid;

    kill 15, $self->xvfb_pid;
}

sub open {
    my ($self, $url) = @_;

    $self->view->open($url);

    Gtk3->main_iteration while Gtk3->events_pending or $self->view->get_load_status ne 'finished';
}

sub eval_js {
    my ($self, $js) = @_;

    my $fn = "___run_js_$$";
    warn "function $fn() { $js }; alert($fn());";
    $self->view->execute_script("function $fn() { $js }; alert($fn());");
    Gtk3->main_iteration while Gtk3->events_pending or $self->view->get_load_status ne 'finished';
    return pop @{ $self->alerts };
}

sub code_for_locator {
    my ($self, $locator, $context) = @_;

    $context ||= 'document';

    if ($locator =~ /^xpath=(.*)/) {
        return "document.evaluate('$1', $context, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue";
    }
    if ($locator =~ /^label=(.*)/) {
        return $self->code_for_locator(qq{xpath=.//*[text()="$1"]}, $context);
    }
    if ($locator =~ /^id=(.*)/) {
        return "document.getElementById('$1')";
    }
    die "unknown locator $locator";
}

sub resolve_locator {
    my ($self, $locator, $document, $context) = @_;

    $document ||= $self->view->get_dom_document;
    $context ||= $document;

    if (my ($xpath) = $locator =~ /^xpath=(.*)/) {
        my $resolver = $document->create_ns_resolver($context);
        my $xpath_results = $document->evaluate($xpath, $context, $resolver, ORDERED_NODE_SNAPSHOT_TYPE, undef);
        my $length = $xpath_results->get_snapshot_length;
        die "$xpath gave $length results" if $length != 1;
        return $xpath_results->snapshot_item(0);
    }
    elsif (my ($label) = $locator =~ /^label=(.*)/) {
        return $self->resolve_locator($label eq '' ? qq{xpath=.//*[not(text())]} : qq{xpath=.//*[text()="$label"]}, $document, $context);
    }
    elsif (my ($value) = $locator =~ /^value=(.*)/) {
        return $self->resolve_locator(qq{xpath=.//*[\@value="$value"]}, $document, $context);
    }
    elsif (my ($id) = $locator =~ /^id=(.*)/) {
        return $document->get_element_by_id($id);
    }
    elsif (my ($css) = $locator =~ /^css=(.*)/) {
        return $document->query_selector($css);
    }
    elsif (my ($class) = $locator =~ /^class=(.*)/) {
        return $document->query_selector(".$class");
    }

    warn "unknown locator $locator";
    die "unknown locator $locator";
}

sub get_xpath_count {
    my ($self, $xpath) = @_;

    my $document = $self->view->get_dom_document;
    my $resolver = $document->create_ns_resolver($document);
    my $xpath_results = $document->evaluate($xpath, $document, $resolver, ORDERED_NODE_SNAPSHOT_TYPE, undef);
    return $xpath_results->get_snapshot_length;
}

sub select {
    my ($self, $select, $option) = @_;

    my $document = $self->view->get_dom_document;
    $select = $self->resolve_locator($select, $document)          or return;
    $option = $self->resolve_locator($option, $document, $select) or return;

    my $options = $select->get_property('options');
    foreach my $i (0 .. $options->get_length) {
        my $current = $options->item($i);

        if ($current->is_same_node($option)) {
            $select->set_selected_index($i);

            my $changed = $document->create_event('Event');
            $changed->init_event('change', TRUE, TRUE);
            $select->dispatch_event($changed);

            Gtk3->main_iteration while Gtk3->events_pending or $self->view->get_load_status ne 'finished';
            return 1;
        }
    }

    return;
}

sub click {
    my ($self, $locator) = @_;

    my $document = $self->view->get_dom_document;
    my $target = $self->resolve_locator($locator, $document) or return;

    my $click = $document->create_event('MouseEvent');
    $click->init_mouse_event('click', TRUE, TRUE, $document->get_property('default_view'), 1, 0, 0, 0, 0, FALSE, FALSE, FALSE, FALSE, 0, $target);
    $target->dispatch_event($click);
    return 1;
}

sub wait_for_page_to_load {
    my ($self, $timeout) = @_;

    Gtk3->main_iteration while Gtk3->events_pending or $self->view->get_load_status ne 'finished';
}

sub wait_for_element_present {
    my ($self, $locator, $timeout) = @_;
    $timeout ||= $self->default_timeout;

    my $document = $self->view->get_dom_document;
    my $element;
    my $expiry = time + $timeout / 1000;

    Gtk3->main_iteration while time < $expiry and (Gtk3->events_pending or not eval { $element = $self->resolve_locator($locator, $document) });

    return $element;
}

sub is_element_present {
    my ($self, $locator) = @_;

    return eval { $self->resolve_locator($locator) };
}

sub get_text {
    my ($self, $locator) = @_;

    return $self->resolve_locator($locator)->get_text_content;
}

sub type {
    my ($self, $locator, $text) = @_;

    $self->resolve_locator($locator)->set_value($text);

    return 1;
}

sub key_press {
    my ($self, $locator, $key, $elem) = @_;

    $key =~ s/\A \\0*(\d+) \z/$1/xme;

    $elem ||= $self->resolve_locator($locator) or return;
    $elem->focus;
    my $display = X11::Xlib->new;
    #warn $display->XKeysymToKeycode(chr($key));
    $display->XTestFakeKeyEvent(36, 1, 1);
    $display->XTestFakeKeyEvent(36, 0, 1);

    # Unfortunately just does nothing:
    #Gtk3::test_widget_send_key($self->view, int($key), 'GDK_MODIFIER_MASK');

    Gtk3->main_iteration while Gtk3->events_pending or $self->view->get_load_status ne 'finished';

    return 1;
}

sub type_keys {
    my ($self, $locator, $string) = @_;

    my $element = $self->resolve_locator($locator) or return;

    foreach (split //, $string) {
        $self->key_press($locator, $_, $element) or return;
    }

    return 1;
}

sub pause {
    my ($self, $time) = @_;
    usleep $time * 1000;
}

sub is_ordered {
    my ($self, $first, $second) = @_;
    return 1;
}

sub get_body_text {
    my ($self) = @_;

    return $self->view->get_dom_document->get_property('body')->get_property('inner_html');
}

sub mouse_over {
    my ($self, $locator) = @_;

    my $document = $self->view->get_dom_document;
    my $target = $self->resolve_locator($locator, $document) or return;

    my $move = $document->create_event('MouseEvent');
    $move->init_mouse_event('move', TRUE, TRUE, $document->get_property('default_view'), 1, 0, 0, 0, 0, FALSE, FALSE, FALSE, FALSE, 0, $target);
    $target->dispatch_event($move);

    return 1;
}

sub get_value {
    my ($self, $locator) = @_;

    my $element = $self->resolve_locator($locator);
    return $element->get_value;
}

sub is_visible {
    my ($self, $locator) = @_;

    return 1;
}

=head2 native_drag_and_drop_to_object($source, $target)

Drag&drop that works with native HTML5 D&D events.

=cut

sub native_drag_and_drop_to_object {
    my ($self, $source, $target) = @_;

    $self->eval_js(<<"    JS");
        var evt = window.document.createEvent("DragEvent");
        var source = window.document.querySelector('$source');
        evt.initDragEvent('dragstart', true, true, window, 1, 0, 0, 0, 0, false, false, false, false, 0, source, {'setData': function(property, data) {}});
        source.dispatchEvent(evt);

        var target = window.document.querySelector('$target');
        evt.initDragEvent('drop', true, true, window, 1, 0, 0, 0, 0, false, false, false, false, 0, target, {'setData': function(property, data) {}});
        target.dispatchEvent(evt);
    JS
}

1;

